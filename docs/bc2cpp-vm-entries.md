# Bytecode the closed build still runs

The closed build compiles the engine's methods to C++, but mruby's VM is still
linked and still runs some code: every gem's mrblib loads as bytecode at boot,
and a few bodies stay bytecode for good. Dropping the VM (and the interpreter
text and irep data with it) needs a list of exactly what enters it, and what
removes each entry. This page is that list.

## How it was measured

A counter in a local, uncommitted patch of `3rd/mruby/src/vm.c` counts every
bytecode body the VM starts: from C (`mrb_vm_exec`) and inside the VM
(`OP_SEND`, `OP_CALL`, `OP_BLKCALL`). The closed host
(`scripts/bc2cpp/trace_host.bash`) ran the five `scripts/bc2cpp/host_sweep.bash`
scenarios (New Game, a battle, the menu, a save, a load) and every twelfth map
for 150 frames: 50 runs. A 1-frame run gives the boot set; "after boot" is a
body's starts minus 50 times its boot starts.

## After boot, 50 runs

| Entry | Before | After | Removed by |
|---|---|---|---|
| `Array#sort` alias (`_rgss_native_sort`) | 8236 | 8236 | #2970 (merged; these counts were taken before it, so the alias no longer enters the VM) |
| `Symbol#to_proc` (method and its lambda) | 720 | 0 | the fork's native `Symbol#to_proc` (`claude/symbol-to-proc-native`; expected, see below) |
| `Enumerable#inject` (method and its `each` block) | 720 | 720 | the fork's `inject` without the lambda (see below) |
| `Proc#call` (and `Proc#[]`) | 563 | 554 | the `default:` lambdas below took 9; the fork's `proc_call` cfunc takes the rest (the method was an `OP_CALL` bytecode body; the procs it calls are counted on their own rows) |
| `BasicObject#!=` | not counted | not counted | the fork's `bob_neq` cfunc (it was an `OP_EQ` bytecode body); not run by the sweep, so no count |
| `LCF::Schema` `elements:` lambdas | 78 | 78 | not yet |
| `LCF::Schema` `default:` lambdas | 9 | 0 | Symbol defaults (`LCF.edition_default`) |
| `Class#new`, `File#initialize` | 14 | 14 | not yet (mruby-io's `File.open`) |

Without the sort alias that is 2104 starts before and 2086 after. The boot set
is about 305 bodies.

## What was removed

- **Edition defaults.** The six `default: -> { LCF.level_max }` and
  `LCF.exp_default` lambdas were made by `schema.rb`'s class body, so they were
  bytecode, and each read of an absent field entered the VM twice (`Proc#call`,
  then the lambda). A `default:` that is a Symbol (`:level_max`, `:exp_default`)
  now names the edition value, and `LCF.to_rb` resolves it through
  `LCF.edition_default`, a compiled module function: a read makes no dynamic
  dispatch (`edition_default_check.rb`). A callable default still works, and the
  wio schema blob is byte-identical. The marker is a Symbol and not an object of
  an engine class on purpose: the registration proof (`load_phase` in
  `static_dispatch_registrations.rb`) counts a class body's blocks, the
  `elements:` lambdas included, as load-time code, and gives up on every
  by-name proof the moment such code may instantiate an engine class (it states
  that none does today). An `EditionDefault` object made in those lambdas left
  5 of 1094 names provable. Whatever replaces the load phase has to keep that
  in mind.

## What stays, and why

- **`elements:` lambdas (18).** Each builds one record type's field table, once
  per process (`LCF.elements_of` caches the Hash back onto the schema entry).
  They are lazy on purpose: building all of them at load raised a
  NoMemoryError on the Wio's 192 KB SRAM. Compiling them is a size loss while
  the VM is linked. A 100-field nested table compiles to about 26 KB more text
  at `-Os` (265 bytes a field), so the roughly 930 fields cost about 245 KB,
  against about 50 KB of bytecode. The way out is to fold them to data at build
  time and decode them with one compiled routine, which is what
  `mruby-lcf/gen_schema_blob.rb` already does for wio.
- **`Symbol#to_proc` (240 conversions, 480 element calls)** was removed by a
  native implementation in the fork (take-cheeze/mruby
  `claude/symbol-to-proc-native`). All of it was in the battle scenario: a
  Symbol passed as a block to a method the compiler did not inline
  (`reject(&:dead?)`, `select(&:defending)` and the like on `@ui[:allies]` and
  `@ui[:foes]`, Hash values the compiler cannot prove are Arrays:
  `scene/battle.rb`, `battle_rpg2k3.rb`). The Ruby method returned a lambda to
  its caller, the case the Fiber rule exists for, so it stayed bytecode. Now
  `src/symbol.c` makes a cfunc proc (`mrb_proc_new_cfunc_with_env`, the Symbol
  in its env, flagged strict so `lambda?` holds) that sends the Symbol to its
  first argument through `mrb_funcall_send`, a `__send__`-equivalent funcall
  (visibility is ignored, `method_missing` applies, keywords and the block are
  forwarded, the callee's argument count is checked), so neither the conversion
  nor a call enters the VM. `block_self_world.rb` holds `symbol.c` to the proof
  `symbol.rb`'s send had (no Symbol passed as a block is a rebinder). The Symbol is still a literal at every call site
  (`static_dispatch_symbol_uses.rb`), so the closed name proof is unchanged.
  Differences from the Ruby lambda: `arity` is -1 (was -2) and `parameters` is
  empty, because a cfunc proc has no aspec; the argument-count message is
  "expected 1+" (was "expected 1").
- **`Enumerable#inject` / `reduce` (720 starts).** mruby's method builds a lambda
  for a Symbol argument, and a core method that builds a lambda stays bytecode
  (`CoreDefs.builds_lambda?`), so every engine `reduce(0) { ... }` runs the method,
  its `each` block per element and a `Proc#call` per element in the VM. An
  engine-level `Array#inject` without the lambda removes all of that (about 1200
  starts per 50 runs), but it costs the closed proof about 940 of 3262 names:
  delegating the Symbol form to core `inject` through an `Enumerable` view
  forwards `*args` into core's computed `__send__`, which the proof cannot
  follow. The fork's `mrblib/enum.rb` now does this (take-cheeze/mruby
  `claude/enum-inject-no-lambda`): `sym = nil` before the `if Symbol === args[-1]`
  guard, no `block = ->(x, y) {...}` line, and
  `result = sym ? result.__send__(sym, val) : block.call(result, val)`.
  `Enumerable#inject` then builds no lambda and compiles like any core method.
- **Class bodies and gem roots at boot.** The boot set is about 305 bodies,
  mostly the 264 class and module bodies and 14 gem roots that run once per
  process. Compiling the load phase is what removes them, and the static irep
  data with them. `BC2CPP_LOAD_COMPILE=all` (the default) does that for the
  engine gems: 420 starts to 385
  ([measured](bc2cpp-class-bodies.md)). The rest of the engine's bodies keep a
  def that a visibility or alias statement names, which needs a second compiled
  phase after the registration; mruby's own mrblib (about 40 bodies) is not
  part of the load world.
