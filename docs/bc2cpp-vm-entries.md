# Bytecode the closed build still runs

The closed build compiles the engine's methods to C++, but mruby's VM is still
linked and still runs some code: every gem's mrblib loads as bytecode at boot,
and a few bodies stay bytecode for good. Dropping the VM (and the interpreter
text and irep data with it) needs a list of exactly what enters it, and what
removes each entry. This page is that list.

## How it was measured

A counter in a local, uncommitted patch of `3rd/mruby/src/vm.c` counts every
bytecode body the VM starts, at five sites: from C (`mrb_vm_exec`, "C_entry"),
`OP_EXEC` (class and module bodies), `OP_SEND`, `OP_CALL` and `OP_BLKCALL`. Each
start is keyed by the method name, the owning class, the kind (method, lambda or
block) and the body's instruction and register counts. The patch writes its tally
to the file named by `BC2CPP_VMCNT_OUT` at exit and does nothing without that
variable. It is never committed.

The closed host (`scripts/bc2cpp/trace_host.bash`, against the closed `libmruby.a`)
ran the scenarios of `scripts/bc2cpp/host_sweep.bash`: New Game, a battle (troop 1,
played to the end), the menu, saves at three menu depths, and a load. That is
seven processes. It also ran every twelfth map of the sorted `Map*.lmu` list
(positions 12, 24, ..., 540: 45 maps) for 150 frames. That is 52 runs in all. A
1-frame New Game run gives the boot set; "after boot" is a body's starts across the
52 runs minus 52 times its boot starts.

The earlier table divided by 50. `host_sweep.bash` runs seven scenario processes,
so the sweep is 52 runs, and the divisor is now the number of runs actually made.

The Before column is the earlier measurement, on the code before the change, copied
unchanged; it was not re-run. The After column is this refresh, on `origin/master`
`f89b525` with the fork pinned at `95f8c40`.

## After boot, 52 runs

| Entry | Before | After | Removed by |
|---|---|---|---|
| `Array#sort` alias (`_rgss_native_sort`) | 8236 | 0 | #2970 (merged); this refresh measured 0 starts |
| `Symbol#to_proc` (method and its lambda) | 720 | 0 | the fork's native `Symbol#to_proc` (`claude/symbol-to-proc-native`); the battle run is included, so the zero covers the path that made the 720 |
| `Enumerable#inject` (method and its `each` block) | 720 | 0 | the fork's `inject` without the lambda (see below) |
| `Proc#call` (and `Proc#[]`) | 563 | 0 | the fork's `proc_call` cfunc; no `OP_CALL` body started in any run |
| `BasicObject#!=` | not counted | 0 | the fork's `bob_neq` cfunc (it was an `OP_EQ` bytecode body) |
| `Hash#to_proc` (method and its lambda) | not counted | 0 | the fork's native `Hash#to_proc`; no scenario converts a Hash, so this zero does not exercise the native path |
| `LCF::Schema` `elements:` lambdas | 78 | 81 | not yet; 13 distinct bodies (by instruction and register count) started, 6 of the 393 starts are at boot |
| `LCF::Schema` `default:` lambdas | 9 | 0 | Symbol defaults (`LCF.edition_default`); no `default: ->` lambda is left in `mruby-lcf/mrblib/schema.rb`, and none started |
| `Class#new` | 14 (with `File#initialize`) | 0 | the fork's native `Class#new` (`class_new_instance`) |
| `File#initialize` | in the 14 | 0 | the fork's native `File#initialize` (`mrb_file_init`); no run started it |

Every After value above was measured in this refresh. The Before values are the
earlier measurement, carried over. `BasicObject#!=` and `Hash#to_proc` were never
counted before, so they have no Before number.

Without the sort alias, the earlier after-boot total was 2086 starts (2104 before).
In this refresh the VM starts 185 bodies after boot in all, and only three bodies
account for them: the `elements:` lambdas (81), blocks named `to_a` whose owning
class is anonymous, entered from C (100), and `Enumerable#to_a` (4). Nothing else
starts in any of the 52 runs. Those two `to_a` groups are not in the table above;
the census does not say which class the anonymous one belongs to.

## Boot set

The 1-frame New Game run starts 293 bodies (177 distinct bodies): 182 `OP_EXEC`
(class and module bodies), 69 `OP_BLKCALL` (blocks), 27 entered from C, and 15
`OP_SEND`. The earlier figure, about 305 bodies, came from the earlier counter and
is replaced by this one.

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

- **`elements:` lambdas (18 in the source).** Each builds one record type's field
  table, once per process (`LCF.elements_of` caches the Hash back onto the schema
  entry). They are lazy on purpose: building all of them at load raised a
  NoMemoryError on the Wio's 192 KB SRAM. In this refresh 13 distinct bodies
  started, 81 times after boot in 52 runs. Compiling them is a size loss while
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
- **`File#initialize`** (mruby-io's `File.open`, through `IO.open`'s `self.new`) was a Ruby
  method of `mrblib/file.rb` whose explicit-argument `super(fd, mode)` the core compile
  refused (`unhandled opcode SUPER`, measured with a debug hook on `super_lookup_call`).
  The by-name `super` lookup needs the class's superclass as a String and either a
  `&blk` parameter or the whole-program "no caller passes a block" fact. The core job has neither:
  `build_registry` keeps the *last* `class File` it walks, and mruby-io's
  `file_constants.rb` reopens it without a superclass (`:none`), over `file.rb`'s
  `class File < IO`; and the call facts are off in that job. Fixing the first changes
  every class reopened without a superclass, so the fork defines it natively
  instead (`mrb_file_init` in `file.c`: the path kept in `@path`, `IO.sysopen`, then
  `IO#initialize` looked up from `File`'s superclass and called with the block it got).
- **`Class#new`** was a hand-written static irep in the fork's `src/class.c`
  (`allocate`, then `initialize(*args, **kw, &blk)` by self-send), so every `new` the
  compiler did not inline ran in the VM. It is now `class_new_instance`, a cfunc in
  the Class ROM table that allocates and sends `initialize` with `mrb_funcall_send`
  (private methods callable, `method_missing` applies, keywords and block forwarded,
  the callee's argument count checked). `initialize` therefore runs under a C frame,
  as it already did under `mrb_instance_new`; a `Fiber.yield` inside it now raises
  `FiberError` instead of suspending, which is the model the yield analysis already had
  ([yield C boundary](bc2cpp-yield-c-boundary.md)). `EnumeratorModel` reads the two
  names `Class#new` sends from the function's text instead of the irep's presyms.
  The table's bytecode entries are then `File#initialize` and `Enumerator::Yielder#<<`
  (`File#initialize` goes with the next change, `Yielder#<<` with the Enumerator-free list).
  In this refresh both have 0 starts, and `Enumerator::Yielder#<<` appears in no row.
- **`Hash#to_proc`** was mruby-hash-ext's `->x{self[x]}`, a lambda returned to
  its caller, so it stayed bytecode (the last method of the Symbol#to_proc kind).
  `src/hash_ext.c` now makes a strict cfunc proc with the Hash in its env that reads
  it with `[]` (a subclass's `[]`, the default value and the default proc apply)
  and takes exactly one argument, as the lambda did (`mrb_get_args "o"`). Same
  difference as `Symbol#to_proc`: `arity` is -1 (was 1) and `parameters` is empty.
  `block_self_world.rb` cuts the one registration line that spells `to_proc` from
  `hash_ext.c` before its blanket native scan (the file sends a fixed `[]`, no
  computed name and no block).
  The method table keeps its entry (it is a ROM entry now); the bytecode entries
  of the table go from 4 to 3 (`Class#new`, `File#initialize`,
  `Enumerator::Yielder#<<`).
- **`Enumerable#inject` / `reduce` (720 starts per 50 runs before).** mruby's method builds a lambda
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
  In this refresh it has 0 starts.
- **Class bodies and gem roots at boot.** The boot set is 293 starts in this refresh
  (see Boot set above), 182 of them class and module bodies. Compiling the load
  phase is what removes them, and the static irep data with them.
  `BC2CPP_LOAD_COMPILE=all` (the default) does that for the engine gems: the
  [class-bodies measurement](bc2cpp-class-bodies.md) gives 420 boot starts before and
  385 after. That figure is not reproduced here: this refresh's full boot set is 293
  starts under the same compiled load, so the two counts differ in method or build
  and need reconciling. The statements run from a byte program and one decoder,
  which changes the load's text and not its VM starts. The rest of the engine's
  bodies keep a def that a visibility or alias statement names, which needs a second
  compiled phase after the registration; mruby's own mrblib (about 40 bodies) is not
  part of the load world.
