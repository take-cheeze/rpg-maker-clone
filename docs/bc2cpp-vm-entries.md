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
| `Symbol#to_proc` (method and its lambda) | 720 | 720 | not yet |
| `Enumerable#inject` (method and its `each` block) | 720 | 720 | the fork's `inject` without the lambda (see below) |
| `Proc#call` | 563 | 554 | the `default:` lambdas and the `elements:` lambdas below; the rest call `inject` blocks |
| `LCF::Schema` `elements:` lambdas | 78 | 0 | folded to byte tables (below) |
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

- **`elements:` lambdas.** Each of the 18 builds one record type's field table
  (DATABASE's player, skill, item, ...; MAP_UNIT's map fields) once per process
  (`LCF.elements_of` caches the Hash back onto the schema entry). They are lazy
  on purpose: building all of them at load raised a NoMemoryError on the Wio's
  192 KB SRAM. As bytecode they entered the VM twice on first use (`Proc#call`,
  then the lambda); compiled to C++ they would cost about 245 KB of text at
  `-Os` (265 bytes a field, some 930 fields). In a build with compiled gems
  (not wio, which has `gen_schema_blob.rb`) `mruby-lcf/gen_schema_tables.rb`
  now loads `schema.rb` under CRuby, calls each lambda once and writes
  `schema_tables.cc`, 18 byte tables and a string pool in `.rodata`, and a copy
  of `schema.rb` in which each lambda is its table number (same lines).
  `LCF.elements_of` hands an Integer to `LCF.schema_table`, a native routine
  (`src/schema_tables.hxx`) that builds the Hash on that first read, and
  caches it as before; nothing is built at load. A table names the schema's own
  shared constants (`elements: SE`) as references, so the object sharing is
  kept, and keeps the keys' order. `schema.rb` stays the one source, plain Ruby
  that CRuby loads. `scripts/bc2cpp/lcf_schema_tables_check.rb` decodes every
  table with a real mruby, with a full collection before every value, and
  compares the whole of `LCF::Schema` (lambdas called under CRuby, tables
  decoded under mruby) as text. Measured (closed build, clang 18): the schema
  is 38,136 B of irep without debug info and 14,418 B folded; the tables and
  strings are 13.4 KB and the decoder 2.2 KB at `-Os`, so 8 KB less; the New
  Game run (3000 frames) starts 14 fewer bodies and the battle scenario 24.
  The string pool is the larger part of the data (520 names); a compact
  encoding of it is the next saving. The registration proof reads native
  sources for method names, and every C string literal counts as one: the
  decoder spells no field key (`type` among them) and takes them from the pool,
  or four classes' `type` left the closed list.

## What stays, and why

- **`Symbol#to_proc` (240 conversions, 480 element calls).** All of it is in the
  battle scenario: a Symbol passed as a block to a method the compiler did not
  inline. The sites are `reject(&:dead?)`, `select(&:defending)` and the like on
  `@ui[:allies]` and `@ui[:foes]`, Hash values the compiler cannot prove are
  Arrays (`scene/battle.rb`, `battle_rpg2k3.rb`). `Symbol#to_proc` returns a
  lambda to its caller, the case the Fiber rule exists for, so it stays
  bytecode. Writing those blocks out would remove it, or a native
  `Symbol#to_proc`; `&:sym` sends through `__send__`, which ignores visibility,
  so each method's visibility has to be checked first.
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
  data with them.
