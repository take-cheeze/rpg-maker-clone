# Class bodies as generated C++ (LOAD_COMPILE)

A class or module body runs once, while mrblib loads: `CLASS`/`MODULE`/`SCLASS` open a scope, `EXEC` runs the body's
irep, `TDEF`/`SDEF`/`DEF`+`METHOD` install the methods, and `SETCONST`, `ALIAS` and the `include`/`attr_*` sends do the
rest. bc2cpp's method compiler has no case for any of those opcodes, so every body stayed bytecode.

`tools/bc2cpp/load_compile.rb` splits each engine gem's mrblib into two parts that together do what the whole did:

| part | what it is | when it runs |
| --- | --- | --- |
| residual | the mrblib text with the compiled statements blanked (newlines kept: line numbers and backtraces are unchanged) | first, as bytecode, in the base gem's init |
| compiled load | `bc2cpp_load_<symbol>(M)`, generated C++ | first thing in the `*-compiled` gem's `gem_init`, before the compiled methods are registered |

`ClassBodyScan` (`tools/bc2cpp/class_body_scan.rb`) sorts every statement of every body. In the closed world's 278
bodies there is no DSL call and no proc statement; what blocks is 6 `mruby-io` runtime globals, one core `if`, and four
engine constants computed by a lambda or `each` (`SYSTEM_SFX_SAVE_FIELD`, `DATABASE`, `MAP_UNIT`, `EXT_SPELLINGS`).
`scripts/bc2cpp/class_body_report.rb` prints the table per gem, the blocker sites and the load-phase opcode histogram.

## Modes

`BC2CPP_LOAD_COMPILE` (read by `compiled_gems.rb`, `bc2cpp.rb`):

- `off`: nothing changes.
- `defs` (default): the residual loses the `def`s the stub proof lets go (`MrblibStubs.stubbable`), entirely instead of
  being emptied to `raise ScriptError`. No load code, no marker. The size win is here: the method ireps are 91k of the
  load phase's 104k instructions.
- `all`: the statements are compiled too (nesting, mixins, `attr_*`, visibility, alias, literal and pure constants,
  class ivars). The residual's last file sets `$__bc2cpp_residual_<symbol>`, and the load is a no-op without it, so a
  build, a phase 1 stub generation or a second load that has the full mrblib is unchanged.

## What the compiled load keeps equal

The load replays the VM's own rules (`mrb_vm_define_class`/`module`, `mrb_singleton_class`, `mrb_const_set`, the
lexical `mrb_vm_const_get` order, `alias_method` through a funcall, `attr_*` through `mrb_funcall_argv`) one statement
at a time with the arena restored after each, so an exception or a GC sees the same state. A body that cannot be
compiled keeps its text and bytecode statement by statement; nothing is all-or-nothing.

Moving a statement behind residual ones is sound only if they cannot observe it, so:

- a residual statement that reads a constant makes the statement that defines it residual too (promotion; matched by
  the last constant segment, pessimistically);
- a class header the residual needs (a superclass, an outer scope) stays;
- a `def` that a compiled statement names (`private :x`, `alias_method`) stays, because that statement runs before the
  compiled gem has installed anything (pinning).

`scripts/bc2cpp/class_body_check.rb` loads fixtures three ways (interpreted; residual + compiled load + the dropped defs
added back; ungated) and compares classes, superclasses, ancestors, constants and their values and frozenness, class
ivars, method tables with visibility, and reopen/redefine ordering. It also runs the planner on the real gems with every
def dropped.

## Class graph facts

`tools/bc2cpp/class_world.rb` states the class graph from source: per class and module the superclass, the includes and
prepends, the ancestors, the singleton class's chain, whether it is final (no subclass in the closed world, `Class.new`
included), whether more than one body opens it, and which of its bodies the load can evaluate statically and which keep
bytecode and why. `class_body_report.rb --world=FILE` writes it as JSON with a summary. A class is `exact` when every
body that opens it, and every ancestor's, contains only modeled statements; otherwise it is unknown with the reason
named, and unknown spreads to its subclasses. Nothing in code generation reads it. The check compares every exact
fixture class with the interpreted graph.

## Symbol names after a def leaves the mrblib

A registration interns its method name by string. While the mrblib had the `def`, the name was a presym (a binary
search); once the def is gone it is not, and mruby's runtime symbol table (256 buckets, `uint8` chain links) answers a
miss with a walk over every symbol. A first `all` build without a countermeasure took 68 ms to `mrb_open` instead of
14 ms (thousands of `bc2cpp_left_out`/`mrb_define_method` misses). So a build that drops defs (the plan's
`BC2CPP_LOAD_WORLD`) also emits `bc2cpp_registration_presyms`, a never-used table of `MRB_SYM(name)` for every
registered name (`emit_registration_presyms`): the presym scan reads it from the preprocessed source and the names
stay presyms. A probe built against a fixed presym header does not get it.

## Measured (closed build, `-O0`, `libmruby.a` as a whole; pin 9153127)

| | `off` (today: stubbed bodies) | `all` |
| --- | --- | --- |
| data | 1,432,093 B | 1,067,713 B (-364,380) |
| text | 18,815,761 B | 18,739,967 B (-75,794) |
| `mrb_open` | 13-14 ms | 13-14 ms |
| 1,241 class/constant probes (value, class, frozen) | | identical |

Static irep data of the engine gems (`rite -g`): 3,149 ireps / 439,646 B today, 382 / 89,619 with the compiled load,
406 / 149,418 with defs only. At `-Os` the load code is about 125 KB (blobs and helpers included) against the data it
replaces, so statement compilation is roughly size-neutral; the size comes from not installing the defs.

`defs` (the default), built and booted after merging master: `libmruby.a` data 1,071,325 B, `mrb_open` 10 ms, the same
1,241 probes as `off`. Before `defs` kept every body header there, a build that deleted a whole body booted without its
classes; `class_body_check.rb` now checks that no body is deleted in `defs`.
