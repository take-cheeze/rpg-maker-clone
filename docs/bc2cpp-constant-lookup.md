# Generated lexical constant lookup

A bare constant in a compiled method is looked up in the order of mruby's `mrb_vm_const_get`
(`3rd/mruby/src/variable.c`): the own table of each lexical scope, innermost first and Object last, then the
ancestors of the innermost scope (for a module, Object's chain after its own), and finally `const_missing` on the
innermost scope. The owner's nesting stands in for the lexical chain (`Game::Character` gives Game::Character, Game,
then Object). An outer scope's own constant therefore wins over a superclass's: in `module Outer; W = 1; class Sub <
Base; def w = W` the read is `Outer::W` even when `Base::W` exists, and a top-level `W` wins over `Base::W` in a
top-level `class Sub < Base`. The generator shares one C++ helper per owner path rather than repeating the path
reconstruction and search at every GETCONST instruction; different names pass their interned symbol to the same
helper. Top-level Object lookups remain direct `mrb_const_get` calls.

The helper reconstructs the complete scope path before searching it, so a missing enclosing scope still raises. A
miss in one table is answered without raising (`mrb_iv_defined` on the class); only a name found nowhere reaches the
raising `mrb_const_get`. The helper caches nothing: reassignment stays visible. The proven per-site caches below use
it on their slow path. `scripts/bc2cpp/const_lexical_order_check.rb` runs reads where these steps disagree,
interpreted and compiled, and compares the results.

## Per-site constant cache (CONST_SITE_CACHE)

A bare constant whose one binding the closed world can prove never changes is
read from a per-site slot after its first lookup. `tools/bc2cpp/const_site_cache.rb`
holds the proofs; the same rules apply to both kinds:

- **Class/module values** (`StableClassConstants`): every `class`/`module`
  statement for the name opens the same qualified path, no SETCONST/SETMCNST of
  it, no native or foreign definition, and no `const_set`/`remove_const` in the
  program. Only a class or module result is stored. The paths come from
  `UniqueClassNames.bytecode_class_paths`, which walks the class bodies from the
  root irep. A statement whose outer scope it cannot name counts as an unknown
  path and refuses the name. Reopening a module at its own path finds the one
  constant and binds nothing new, so `module LCF` in every file of mruby-lcf and
  `module RPG2k` in every scene file no longer disqualify those names. Without
  the root irep the rule is exactly one statement, as it was.
- **Other values** (`StableValueConstants`, CONST_VALUE_CACHE): exactly one
  SETCONST/SETMCNST of the bare name, no class/module statement, and no native or
  foreign definition, under the same `const_set`/`remove_const` refusal. Any
  value the one binding holds is stored. This covers constants bound by a
  computed masgn such as optcarrot's `CLK_1, ... = (1..8).map { ... }`, which
  no literal fold admits.

Both proofs are keyed by the bare name, so two bindings of the same name in
different scopes (`RGSS::Window` and `RPG2k::Window`, or a `SCREEN_W` in each
scene class) disqualify it. A failed lookup raises before anything is
stored, and a read before the binding runs also raises, so it is never cached.

Effect on the closed RPG2000 world: reads that walk the lexical scope chain on
every execution fell from 1,734 sites to 968 in `rpg2k_compiled_gen.cpp` and from
69 to 39 in `lcf_compiled_gen.cpp`. On the headless Nepheshel host
([trace host](bc2cpp-trace-host.md), New Game plus a played battle, 1,200
frames) the run went from 5.36 G to 5.14 G instructions, the same output.
`scripts/bc2cpp/const_site_cache_check.rb` checks the proof.

Effect on the optcarrot probe: `const_get` calls fell from about 1.36 million
over 20 frames to under 18 thousand, and frame-loop instructions dropped from
1.76 G to 1.42 G (`callgrind`, 19-frame difference).

A full RPG2k source sample decreased from 19,695,404 to 17,099,986 bytes
(13.2%), and from 386,389 to 336,973 lines (12.8%). It contains 4,874
lookup calls sharing 92 owner helpers. This is a source-size measurement;
GCC 15.2 at `-O0` also reduced the object from 12,834,984 to 10,416,752
bytes (18.8%), with its text section decreasing from 9,583,112 to 7,576,386
bytes (20.9%). Optimized binary size and runtime performance depend on the
C++ compiler's inlining decisions.

## Names bound at several paths (CONST_BINDING_CACHE)

The proofs above are keyed by the bare name, so `Window` (`RGSS::Window` and `RPG2k::Window`) or a `SCREEN_W` in every
scene class still ran the scope walk at every read. `ConstBindings` (`tools/bc2cpp/const_site_cache.rb`) lists every
binding of such a name instead, with its owner path, when each one is made once and never changed: every
class/module statement for the name opens a known path, every SETCONST of it sits in a body that runs once (the root
or a class/module body with no backward branch) under a known lexical scope, each path is bound once, and nothing
else binds it (no SETMCNST, no native value constant, no foreign definition, the same `const_set`/`remove_const`
refusal).

A native class or module definition (`mrb_define_class_under(M, rgss, "Window", ...)`) is one more owner when its
outer scope can be named: made at gem init and never rebound, it is as fixed as a class statement. The outer is a
module the same function defines with `mrb_define_module(M, "X")` or looks up with `mrb_module_get`/`mrb_class_get(M,
"X")`, directly or through a parameter its callers pass (a prototype is not a call); a lookup names X only when X's
one binding is at the top level. A native value constant (`mrb_define_const`, `mrb_const_set`) still refuses its
name, and a project source that binds a name the scan cannot read refuses every name (mruby's own C is trusted, as
in the closed-world scan).

Once all of those bindings exist, a read's answer is fixed: the scopes it walks and their superclasses do not change,
and no binding is left to appear. The site's helper therefore stores its result only when every owner holds the
name in its own table (`bc2cpp_const_path_has`), and when the owner's own scope path exists; a read before a
binding is made keeps running the full lookup. An include could still reorder what an ancestor walk finds, so a name
is refused when an owner is prepended or included anywhere but Object, when more than one owner is mixed into Object
(Kernel counts), or when any mixin is unresolved. The scope path's segments must themselves be immutable names.

A `Scope::NAME` read (GETMCNST) of a name with only immutable bindings, from a receiver that is `::` or an immutable
constant on every path, caches per site with the receiver it was read from: a binding in the receiver's own table is
the one `mrb_const_get` returns, and it never changes. A receiver whose own table lacks the name is not stored. Inside a
`begin`/`rescue` range the dataflow refuses to name the receiver's writer; there the `A::B` chain still qualifies when
the instruction just before the read wrote the receiver from a constant and nothing else (no jump, no handler) enters
between them. In an inlined body the instruction's registers are shifted, so the writer is looked up at the
unshifted register.

Effect on the closed RPG2000 world, counting the reads in method bodies of `rpg2k_compiled_gen.cpp` that still run
the full lookup (a cache helper's own slow path is not counted):

| | scope walks | `Scope::NAME` lookups |
|---|---|---|
| before the binding cache | 600 | 607 |
| with it (Ruby bindings only) | 210 | 196 |
| native class owners and the rescue-range receiver | 46 | 7 |

What remains is a name a foreign Ruby source also binds (`NameError`, 21 sites) and native value constants (`GAME_DIR`,
the `RPG2K_*` switches, `Math::PI`). On the Nepheshel trace host (New Game plus a played battle, 1,200 frames) the
Ruby-binding step took the run from 1.760 G to 1.693 G instructions with the same output; the 1-frame load is
unchanged.

`scripts/bc2cpp/const_bindings_check.rb` checks which names qualify (native owners and lookups included), that a scoped
read inside a rescue range is cached, and runs reads from every scope interpreted and compiled, before and after a
declared binding is made, comparing the output.

## Slot lifetime (VM_CACHE_LIFETIME)

The CONST_SITE_CACHE, CONST_BINDING_CACHE and OWNER_CLASS_CACHE slots are file-scope statics holding one VM's values.
A hit is an inline slot load (`bc2cpp_cconst_N`, `bc2cpp_mcnst_N`, `bc2cpp_owner_class_N`) with no `mrb_state`
compare; only the out-of-line fill (`bc2cpp_cconst_fill_N`, `bc2cpp_mcnst_fill_N`, `bc2cpp_owner_class_lookup`) looks
at the VM. A GETMCNST slot is keyed by the receiver's `RClass*`, since only a class or module receiver is stored.

The slots are cleared (`bc2cpp_reset_const_site_cache`, `bc2cpp_reset_owner_classes`) by each compiled gem's
`gem_init` and `gem_final` (`bc2cpp_gem_init` / `bc2cpp_gem_final`, emitted by `emit_gem_hooks`), and by `scripts/bc2cpp/fixture_runtime.rb` after each VM it closes. The init reset is the
one the game relies on: its deferred per-maker gem init (`rpg_maker_gem_dispatch` in `build_config.rb`) calls the
gems' init functions without registering their finals, so `gem_final` never runs there. A new VM therefore never reads
a pointer from an earlier one, even at the same address.

Two live VMs running compiled code at once are not supported, as for the DIRECT_CONSTRUCT_ACCESSORS class
pointers: every host (`src/main.cxx`, `scripts/bc2cpp/trace_host.cxx`, `app/psp`,
`app/wio`) opens one VM at a time, and mrbtest never loads the compiled gems (they are only in the single-format bc2cpp
builds, which do not enable tests). A fill records its VM and stops with `mrb_bug` when another VM is still recorded,
so such a run fails loudly at its first miss rather than reading the other VM's values.

Effect on the Nepheshel trace host (closed build, New Game plus a played battle, same output): the 1-frame load went
from 379.12 M to 377.40 M instructions, and the 1,200-frame run spent 13.7 M fewer instructions (0.76% of 1.79 G) outside
LVGL. The 1,200-frame totals vary by several million instructions between runs of one binary, because LVGL's refresh
follows the wall-clock tick, so the comparison leaves the LVGL functions out (their sum varied by up to 5.8 M between
runs of the same binary). The trace host's text grew by 150 KB (1.2%).

## Constant definitions in the numeric and class pools

The numeric proof and the class pools (ADR 0276, 0296, 0301) read a constant's class set from the definitions it
reaches. Those are keyed by the definition's qualified name, resolved lexically by `tools/bc2cpp/lexical_consts.rb`
(ADR 0423): a bare read takes the first scope of its lexical chain that defines the name, and is refused (falls back
to the integer-constant proof or OTHER) when another definition reachable from that lookup could be read instead.
`Game::Character::TURN_LEFT` and `Game::MoveRoute::TURN_LEFT` therefore keep their own pools. `BC2CPP_LEXICAL_CONST=0`
keys by bare name again.

`ruby scripts/bc2cpp/lexical_const_check.rb` checks the resolution and each refusal against compiled fixtures (it needs
`MRBC`).

The writers a lexical question reads are the reaching definitions of its register (`BytecodeIR.writers_reaching`), not
the textually preceding one. A `Holder::NAME` read whose holder register is a ternary, a superclass that is a ternary and
an `include` whose argument is a ternary each need every arm to agree; otherwise the read is refused.
`ruby scripts/bc2cpp/constant_proofs_check.rb` checks those joins (it needs `MRBC`).

## Resolving a constant name from the closed world

`UniqueClassNames.resolve` (`tools/bc2cpp/unique_class_names.rb`) answers what a bare name read from a class body
refers to, following Ruby's order: the owner's lexical scopes (innermost first, top level excluded), then the owner's
ancestors in MRO order (its included modules, last include first, then its superclass and so on), then Object's own
constants and finally Object's mixins (`class Object; include RGSS; end`). Each step reads only the closed world's
class facts, so an answer is given only when every step it passed is known. A step is refused, and the name stays
unresolved, when the class has a prepended module, when an include cannot be resolved, when an included module itself
includes or prepends something, or when the name is bound natively or by an assignment. A module owner has no
superclass, so its search goes from its includes straight to Object.

A foreign Ruby source (a file the closed world does not compile) refuses a name only when it rebinds it (`NAME = value`),
opens a class or module inside another scope, or defines a top-level class the closed world does not know. A column-0
`class X` that reopens a class already bound at top level (`class Array` in mruby's mrblib) leaves the binding alone,
and a column-0 `class X < Y` defines X under Y (mruby's `NameError`, `StopIteration`), whose own includes stay unknown.

### Native-only classes

A class a native source defines once (`mrb_define_class_under(M, RGSS, "Rect", ...)`) and no Ruby source reopens
reaches the unique-name table under its bare name (`Rect` to `RGSS::Rect`), so a `Rect.new` in an engine method
resolves to that class. Its admission (`native_only_classes` in `tools/bc2cpp/unique_class_names.rb`) requires one
native binding at one full path, no bytecode or Ruby class/module statement of that bare name, no SETCONST/SETMCNST
in the bytecode or in the Ruby sources the build reads as bytecode, no foreign text assignment or class statement
naming it, a unique scope for the full path, and no constant mutation the closed world cannot see (const_set,
remove_const, eval, string instance_eval/class_eval/module_eval, a native mrb_const_set with a computed name, or
mrb_load_*). Without the compiled Ruby sources nothing is admitted.

The admitted constant then counts as stable, so a `.new` of it no longer needs the runtime class-identity guard and its
mrb_funcall fallback. The alias form (`Rect = RGSS::Rect` in an interpreted file) is not admitted: the same proof
refuses it, because the assignment is a write to the name.
