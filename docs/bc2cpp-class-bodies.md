# Class bodies as generated C++ (LOAD_COMPILE)

A class or module body runs once, while mrblib loads: `CLASS`/`MODULE`/`SCLASS` open a scope, `EXEC` runs the body's
irep, `TDEF`/`SDEF`/`DEF`+`METHOD` install the methods, and `SETCONST`, `ALIAS` and the `include`/`attr_*` sends do the
rest. bc2cpp's method compiler has no case for any of those opcodes, so every body stayed bytecode.

`tools/bc2cpp/load_compile.rb` splits each engine gem's mrblib into two parts that together do what the whole did:

| part | what it is | when it runs |
| --- | --- | --- |
| residual | the mrblib text with the compiled statements blanked (newlines kept: line numbers and backtraces are unchanged) | first, as bytecode, in the base gem's init |
| compiled load | `bc2cpp_load_<symbol>(M)`: a byte program and one decoder (below) | first thing in the `*-compiled` gem's `gem_init`, before the compiled methods are registered |

`ClassBodyScan` (`tools/bc2cpp/class_body_scan.rb`) sorts every statement of every body. In the closed world's 278
bodies there is no DSL call and no proc statement; what blocks is 6 `mruby-io` runtime globals, one core `if`, and four
engine constants computed by a lambda or `each` (`SYSTEM_SFX_SAVE_FIELD`, `DATABASE`, `MAP_UNIT`, `EXT_SPELLINGS`).
`scripts/bc2cpp/class_body_report.rb` prints the table per gem, the blocker sites and the load-phase opcode histogram.

## Modes

`BC2CPP_LOAD_COMPILE` (read by `compiled_gems.rb`, `bc2cpp.rb`):

- `off`: nothing changes.
- `defs`: the residual loses the `def`s the stub proof lets go (`MrblibStubs.stubbable`), entirely instead of
  being emptied to `raise ScriptError`. No load code, no marker. The size win is here: the method ireps are 91k of the
  load phase's 104k instructions.
- `all` (default): the statements are compiled too (nesting, mixins, `attr_*`, visibility, alias, literal and pure
  constants, class ivars). The residual's last file sets `$__bc2cpp_residual_<symbol>`, and the load is a no-op without
  it, so a build, a phase 1 stub generation or a second load that has the full mrblib is unchanged.

`all` was behind a switch because it did not pass the host sweep: 103 of the 543 maps, the new game and the battle
died with a `SystemStackError`. The cause was the source order of an `alias_method` and a redefinition (below), the
only difference between the compiled load and the interpreted one that the engine's mrblib showed.

## Source order

The residual runs first, then the compiled load, then the compiled gem installs the methods the residual dropped. A
compiled statement therefore sees every residual def, whatever the source order was. Two shapes depend on the order:

- `alias_method :old, :run` above `def run`: the alias must hold the method that existed when it ran.
  A send or alias that takes a name (`taken_names`: `attr_writer :a` takes `a=`) which a def of the
  same owner defines *later in the source* stays residual, in its place among the residual defs
  (`LoadCompile.order!`). RGSS's native delegates are captured in native initialization instead.
- `def a` above `attr_reader :a`: the attr must win. A def that comes before a statement defining the same name is
  kept (`order_pins`), or the compiled gem would install it over the attr.

The source order is the world's: gems in build order, files in order, statements in order. `class_body_check.rb` has
both shapes in its fixture (`Cb::Redef`); unfixed, the equivalence run recurses.

## The class program

The statements of the bodies are not C++ calls, they are bytes (`LoadCompile.program`): one array per gem and one
decoder, `bc2cpp_ld_run`, that walks it. A call per statement was most of the load's code (a nesting is three calls and
a scope, an `attr_accessor` a symbol per name); a statement is now a few bytes.

| op | what it runs |
| --- | --- |
| `CLASS`, `MODULE` | `mrb_vm_define_class`/`mrb_vm_define_module` for a name, a base (the body's class, `Object` or an expression) and a superclass; then the body's own ops, up to its `END` |
| `SCLASS` | `class << self`, then its ops |
| `CONST` | a run of constants: a name and a value each, set in order with the arena given back after each |
| `IVAR` | a class-level `@x = value` |
| `SEND`, `SENDN` | a send with the body's class as receiver: `include`, `extend`, `prepend`, `attr_*`, `alias_method` (an `alias` is one), `private :a`, ...; `SENDN` takes Symbol arguments as names alone |
| `FN` | a statement kept as C++ of its own (below) |

A value is a *blob*: nil, true, false, Integer, Float, Symbol, String (frozen or not), Array (with splat), Hash, Range,
a constant looked up lexically (`A`, `A::B`, `::A`), `.freeze` and, since the program, any other pure call
(`Color.new(1, 2, 3, 4)`, `OTHER.merge(...)`: receiver, name and up to 8 arguments, sent as `OP_SEND` would). Names and
verbs are indexes into one string pool, so the program holds no Ruby method name as a C string (the registration
proof reads C++ string literals as uses). An Integer is a zigzag varint of at most 32 bits; a wider one is not data
(above). A first version read it into an `unsigned` and made `LCF::INT32_WRAP` 2147483648, so every negative number read
from a file came out as `2**31 - 3` (a parallax speed of -3 shifted by that on the 5902nd frame of the New Game run);
`class_body_check.rb` holds the edges and a negative. The decoder reads 64 bits there, so a 32-bit `mrb_int` target
(wasm, wio) and a 64-bit one decode the same bytes.

Order is the source order: the program is one stream per gem, the files in load order, and `LoadCompile.order!`
(above) has already decided which statements are in it. What the program cannot say stays a C++ statement of its own,
called by an `FN` op in its place, so nothing is all-or-nothing:

- a world that defines a hook (`inherited`, `included`, `extended`, `prepended`, `append_features`, `prepend_features`,
  `extend_object`, `method_added`, `singleton_method_added`, ...) keeps the statements the hook observes (a class with a
  superclass; `include`/`extend`/`prepend`; `attr_*`, `alias`, `alias_method`) as C++ statements, and never drops the
  hook defs, which must exist when those statements run (`HOOK_DEFS`, `legacy?`). The program makes the same calls the
  VM would and so would run the hook too; keeping them apart is the cautious reading of "preserve the hooks", and the
  engine defines none, so nothing is C++ per statement today;
- a send of more than 64 names, a call of more than 8 arguments.

## Computed constants, evaluated at build time

A constant built by a block (`X = (0..11).each_with_object({}) { |slot, h| h[slot] = 91 + slot }.freeze`) cannot be a
blob, but its value can: `tools/bc2cpp/pure_eval.rb` (`PureEval.fold`) runs it once under CRuby while the plan is made,
and the program spells the result. It folds a constant only when nothing in it can differ between the build machine and
the device:

- it reads literals, the core classes, and earlier constants of the *same body* that are themselves pure, replayed
  first in source order, with nothing but defs, declarations and constants between them and it, and the container each
  of them holds frozen (a read that could change before the statement ran is not folded);
- it calls only the methods on `PureEval::METHODS` (arithmetic, the Array/Hash/String/Symbol/Range/Integer methods an
  mruby build has and that read neither the environment, the clock, a random source nor a file), always on a receiver,
  so no engine method, no global and no `Foo.new` of an engine class is reachable; `new` is for Array, Hash and String;
- the value is data (`PureEval.value_ok?`): nil, true, false, an Integer inside 32 bits, a Float a float32 holds exactly
  (a 32-bit-float target decodes the same number), a Symbol, a UTF-8 String, and Arrays, Hashes (insertion order kept)
  and Integer Ranges of those; exact classes, no default proc, no ivar, and no unfrozen container or String reached
  twice, since the copy would split it. A frozen container is its bytes under `FREEZE`, a String carries its own
  frozen state.

Anything else stays the statement it was, in the residual. Fidelity is checked against the runtime, not assumed:
`class_body_check.rb` computes each folded constant's statement (with the constants it read) in a booted mruby and
compares it with CRuby's value through one canonical description written to run under both (class, frozen state, order,
content, a Float by its parts because `Float#to_s` differs), on the fixture and on the engine's own mrblib; the
interpreted-against-compiled equivalence covers the rest. `RGSS::Audio::EXT_SPELLINGS` (and `EXTS`, which it read) and
`Game::State::SYSTEM_SFX_SAVE_FIELD` are folded this way. `DATABASE` and `MAP_UNIT`
use the native lazy-data representation instead of eager `PureEval` evaluation.
`LCF::INT32_*` are encoded as decimal data when they exceed a 32-bit `mrb_int`.

Finding while writing the canonical form: this fork's compiler miscompiles `(x ? "A" : "a") + "b"` when `x` is true (the
value is `"A"`, the `+ "b"` is lost; `x = true; ((x ? "A" : "a") + "b")` in the closed build's own VM). The canonical
form builds its strings with `join` to stay clear of it.

## Visibility statements on methods the build leaves out

A def used to stay in the mrblib when `private :x` named it, because the statement runs before the compiled gem has
installed anything. Of the 184 defs the residual of the three engine gems keeps, 133 are kept by the stub proof for its
own reasons (alias source, module_function copy, guard, loaded copy) and 51 by a statement alone. All 51 are left out of
the method tables (`unregistered`: statically dispatched only): the registration removes them right after the load
(`bc2cpp_left_out`). A statement that changes the visibility of something removed before anyone can look it up is dead,
so `LoadCompile.mark_dead!` does not run it (its text is blanked, nothing is emitted) and its defs are free to leave
the mrblib. It applies to `private`, `public`, `protected` (and `private_class_method`, `public_class_method` on the
singleton) whose every name is such a def, with exactly one def of that name in that owner. `module_function :x` and
`alias_method` leave a copy behind and are not dead; a send that names one registered def is still run, and pins every
def it names, as before. No second compiled phase after the registration was needed.

## What stays bytecode

The engine gems now have no residual class-body statements in the planner's
all-definitions-droppable check. `class_body_check.rb` verifies that list stays
empty. Method bodies that fail the compilation or stub proof still retain
bytecode; this is a statement-coverage result, not a claim that the entire
engine has no bytecode.

### Lazy literal data

An initializer can contain zero-argument `-> { ... }` lambdas that return
literal data: numbers, symbols, strings, arrays, hashes, ranges, constant
references, and `.freeze` on those values. The class program stores the body
as data and creates a native Proc without evaluating it. Each call decodes a
fresh result and resolves constants through the captured lexical class/module
objects. Those objects are rooted in the Proc's environment, so they survive
the load frame and garbage collection. Each source lambda has its own native
entry so mruby keeps distinct Procs unequal. Nonzero argument counts are rejected.

Lambdas requiring parameters, locals, `self`, nested closures, arbitrary calls or assignments
stay bytecode. Frozen string literals also stay bytecode because repeated
calls must share the VM's literal object. As with other compiled native Procs,
mruby reports `Proc#arity` as -1; call-time argument checking remains strict.

This lets the raw LCF `DATABASE` and `MAP_UNIT` initializers compile without
forcing their field tables to allocate eagerly. `COMMON_EVENT` no longer has
a residual consumer that pins it. Builds using `gen_schema_tables.rb` retain
their specialized compact table representation.

The RGSS compatibility aliases `Array#_rgss_native_sort!` and
`RGSS::Window#_rgss1_initialize` are captured by native gem initialization,
before mrblib installs their Ruby wrappers. They require no residual alias
statements and keep the original native entries in interpreted and compiled builds.

The core gems are not part of the load world: `mruby-io`'s six runtime globals (`STDIN`, `STDOUT`, `STDERR`, `$stdin`,
`$stdout`, `$stderr`) and the `if` in `numeric.rb` are mruby's own bytecode and stay as it is.

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
  compiled gem has installed anything (pinning); not when the statement is dead (below).

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
named, and unknown spreads to its subclasses. A computed constant that `PureEval` folds (the same decision as
`LoadCompile`'s) is static, so a class whose only blocker is a folded constant is exact.
Literal-data lambdas are native factories and wide integers are decimal data;
unsupported computed constants remain blockers. A superclass that is a C-defined
core class (`ClassWorld::NATIVE`, such as `RuntimeError`) is known. The check
compares every exact fixture class with the interpreted graph; `scripts/bc2cpp/class_world_check.rb` is the fast check
of these rules.

`tools/bc2cpp/class_world_gate.rb` (`ClassWorldGate`) derives the same graph from the closed build's sources (the roots
`class_body_report.rb` reports on) and is the one thing code generation reads from it: `exact_receiver?(klass)` is true only
when the class and every ancestor are exact, and an unknown name is refused. `CodeGen#class_world_exact_target` (codegen_send.rb)
uses it for a receiver whose class the flow names: when the existing closed-world lookup finds no compiled body, the one
public Ruby definition the ancestor chain reaches is called directly behind the TYPED runtime class guard (`CLASS_WORLD_TYPED`).
It refuses any definition on a native, unknown or module owner, a prepend, an unknown mixin, or a name installed at run
time, so such a receiver keeps the owner call. `BC2CPP_CLASS_WORLD_DIRECT=0` turns it off.

Measured on the closed build (shipped C++ from `coverage_report.rb` with `BC2CPP_COVERAGE_KEEP_DIR`; that script's
summary step fails on a stale heading, so the counts come from the kept `shipped.cxx`): 1,896 owner-call sites and
`CLASS_WORLD_TYPED` 0 before and after, the output is byte-identical. The gate is consulted 4,184 times (4,180 for an
exact class, mostly Array, Hash, Range and RGSS classes). Most are refused by the native-definer rule, and the owner-call
sites carry no receiver class from the flow, so the graph alone does not turn any owner-call site into a direct call.
The owner-call direct rows that wait on an exact graph need a receiver-class source for those sites first.
`scripts/bc2cpp/class_world_gate_check.rb` proves the gate on a fixture graph (exact, non-exact, unknown, native definer,
kill switch) and on the closed build's graph.

### Receiver sources measured (closed build, kept `shipped.cxx`)

The 1,896 owner-call sites, by the text of their receiver (a textual measurement of the nearest assignment, not the IR):
`self` 409 (implicit-self sends), a method or call result about 624, a copy of another register about 170, an ivar read
about 75, a fresh allocation about 38, a constant about 14; the rest are nested expressions.

`CodeGen#class_world_self_target` proves the `self` source: an implicit-self send in an instance method of owner C is an
instance of C when C is exact and final (`ClassWorldGate.self_exact?`), the body belongs to C alone, and the ancestor walk
of ClassWorld from C reaches one public Ruby definition. It runs last, after every existing path has declined. On the
closed build it gains no site: the 409 `self` owner calls sit on native holders (Array, Hash, String, StringIO, Kernel,
Enumerable), on a module, or on a non-final superclass (`LCF::SaveTyped::Record`, 17 subclasses). A native holder cannot be
placed by the registry alone, and placing it by `name_owner_set` is memoized per name over the compile context, so calling it
from a new site changed unrelated output (one `CLOSED_WORLD_SELF` site became `MONO`); the finder therefore reads the
registry only. Output is byte-identical to the baseline (`cmp` of the kept `shipped.cxx`).

The other sources (method or call results, ivars, copies of registers) are not proven by a class-graph fact yet: their
receiver class is a value's class, which needs the return-class or ivar-writer flow (RETURN_CLASS_TABLE, ivar writers) per
site. Those stay on the owner call.

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

## Measured: `defs` against `all` (closed build, clang 18, `-O0`; master fa805c8)

| | `defs` | `all` |
| --- | --- | --- |
| `libmruby.a` text | 24,626,025 B | 24,720,999 B (+94,974) |
| `libmruby.a` data | 1,055,797 B | 1,050,813 B (-4,984) |
| the engine gems' `gem_init.o` (mrblib ireps with debug info, init code) | 174,569 B | 125,703 B (-48,866) |
| the compiled load, standalone at `-Os` (lcf 21,149 + rgss 9,288 + rpg2k 76,693) | none | 107,130 B |
| boot VM starts (below) | 420 | 385 |
| host sweep (New Game, battle, menu, three saves, load, 543 maps) | passes | passes |

At `-Os` that is about 58 KB more text for 49 KB less irep: statement compilation is not size-neutral. Before the
constant tables it was 123 KB of load code. The size is the price of the bytecode bodies leaving the boot; what is
left is mostly the nesting and mixin calls, each a C++ call sequence where an irep has one instruction. Folding those
to a byte program with one interpreter, as the constants are, is the next step if the text matters (done: below).

## Measured: the class program (closed build, clang 18, `-Os` standalone; master 40d3bd3)

The compiled load of the three engine gems, generated from the real mrblib with every stub-proof def dropped and
compiled alone (`clang++ -Os -std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION`, `size`):

| | per-statement C++ | program |
| --- | --- | --- |
| lcf | 20,964 B | 15,594 B |
| rgss | 8,751 B | 5,927 B |
| rpg2k | 73,450 B | 38,236 B |
| text (code and `.rodata`) | 103,165 B | 59,757 B (-43,408) |
| data (`.data.rel.ro`: the name tables' pointers) | 3,920 B | 0 |

Each gem's translation unit carries its own copy of the decoder (about 2.7 KB of code); the rest is `.rodata`: the
byte tables and the string pool, which are the same data as before. The 49 KB of irep the load replaces is now paid
back by about 10 KB more text instead of 58 KB.

The whole closed `libmruby.a` (clang 18, `-O0`, the same tree before and after):

| | per-statement C++ (master 40d3bd3) | program |
| --- | --- | --- |
| text | 24,682,233 B | 24,594,753 B (-87,480) |
| data | 1,055,837 B | 1,052,573 B (-3,264) |
| boot VM starts (`mrb_vm_exec` from C / `OP_EXEC` / `OP_SEND` into bytecode / `OP_CALL`, `OP_BLKCALL`) | 56 / 182 / 23 / 69 = 330 | 56 / 182 / 23 / 69 = 330 |
| method table | 1,285 entries | 1,285 entries |
| host sweep (7 scenarios, 543 maps) | passes | passes |

The VM starts do not move: the statements ran as C++ already, the program runs the same calls in the same order. The
win is code size.

## Measured: computed constants and dead visibility statements (same closed build, clang 18, `-O0`; the class program is the base)

| | class program | + folded constants, dead visibility statements |
| --- | --- | --- |
| compiled load, standalone at `-Os` (lcf + rgss + rpg2k) | 59,757 B | 60,027 B (+270: the two values are data now) |
| `libmruby.a` text | 24,594,753 B | 24,588,777 B (-5,976) |
| `libmruby.a` data | 1,052,573 B | 1,045,165 B (-7,408) |
| `mruby-rpg2k` `gem_init.o` (irep and init) text / data | 35,383 / 34,588 B | 31,384 / 27,548 B (-3,999 / -7,040) |
| `mruby-rgss` `gem_init.o` text / data | 5,013 / 5,896 B | 4,815 / 5,528 B (-198 / -368) |
| defs left in the residual `mruby-rpg2k` mrblib | 124 | 73 (the 51 `private :x` ones) |
| boot VM starts (`mrb_vm_exec` from C / `OP_EXEC` / `OP_SEND` / `OP_CALL`, `OP_BLKCALL`) | 56 / 182 / 23 / 69 = 330 | 56 / 178 / 20 / 62 = 316 |
| method table | 1,285 entries | 1,285 entries |
| host sweep (7 scenarios, 543 maps) | passes | passes |

The three engine gems' `mrblib` ireps sit in `gem_init.o`; `mruby-lcf`'s did not change (its plan has nothing to fold or
drop). A probe of the built host reads `EXT_SPELLINGS`, `EXTS` and `SYSTEM_SFX_SAVE_FIELD` (value, frozen state, order)
identically in the build before and after.

Lazy literal lambdas can now be represented by the class program too, so the
raw schema initializers no longer require residual statements.

Boot VM starts, counted as `docs/bc2cpp-vm-entries.md` describes (a 1-frame run and a 150-frame run give the same
numbers: nothing enters the VM after boot on a plain map):

| | `defs` | `all` |
| --- | --- | --- |
| `mrb_vm_exec` from C | 27 | 56 |
| `OP_EXEC` (class and module bodies) | 218 | 183 |
| `OP_SEND` into bytecode | 76 | 47 |
| `OP_CALL`, `OP_BLKCALL` | 99 | 99 |
| total | 420 | 385 |

The C entries grow by the 29 constants the load builds with `Foo.new(...)` (`Class#new` was bytecode in the fork when
this was measured, now a native; the VM ran them as sends before). What remains are the bodies that keep a def: the compiled load runs before the compiled
gem installs its methods, so a def named by `private :x`, `module_function :x` or `alias_method` has to stay as
bytecode for that statement to find it (78 of the 161 kept defs then; 51 of 184 on a later tree). Running those
statements after the registration, in a second compiled phase, would have let those defs go; they did not need it, since
all of them are left out of the method tables and the statement on them is dead (above).

## Source parsing for unit constant folds

Class-body unit constant folding uses `RubyParseCache` for its source lookup.
Repeated candidates and different owners in one file share a Prism tree, while
owner lookup and statement wrappers remain local to each query. Each lookup
still checks the current file bytes: rewritten sources replace the cached tree,
missing files yield no statements, and reopened owners remain ambiguous.

A Ruby 4.0.5 probe made 100 `source_statements` queries for `LCF::Schema` in
`mruby-lcf/mrblib/schema.rb`, starting with an empty cache in each run. Three
alternating uncached/cached runs took 0.244/0.0064, 0.222/0.0056 and
0.219/0.0053 seconds. Allocations fell from about 1,962,763 to 24,947 per
100 queries; the statement source lists matched. This measures source lookup,
including the owner walk and disk reads, rather than total compiler or game
runtime performance.

`scripts/bc2cpp/ruby_parse_cache_check.rb` checks parse reuse across candidates
and owners, absent owners, source rewrites, reopened owners and removed files.
`scripts/bc2cpp/class_body_fold_check.rb` checks emitted folded C++ and refusal
of constants that cannot fold.
