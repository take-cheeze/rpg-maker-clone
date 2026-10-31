# Receiver-aware load phase (design note)

Status: design and measurement only. No behaviour changes in this note's branch. The fixture
`scripts/bc2cpp/load_phase_receiver_check.rb` fails today by design, and
`scripts/bc2cpp/load_phase_chain.rb` reports the load-time chains below.

The question: a method body that load-time code may run is kept as bytecode in a closed build
(`MrblibStubs.stubbable`, `tools/bc2cpp/mrblib_stubs.rb`). `StaticDispatchRegistrations.load_phase`
decides "may run" by method name: one load-time send of `each` keeps every `each` body. This note says what a
receiver-aware version would track, why it is sound, where it differs, and what the measurements say about
whether it would unblock `Range#each`.

Measurements are labelled **measured** (run here, on this tree at `c2b88a2` with the host mrbc of
`/home/user/rpg-maker-clone/build-closed-bc2cpp`, read-only) or **designed** (argued, not run). Scratch
prototypes used for the numbers were not committed.

## 1. How `load_phase` works today

Two callers read it:

- `analyze` (`tools/bc2cpp/static_dispatch_registrations.rb:873-875`): the names load-time code sends become
  `dynamic`, so their registrations are kept; `load_bodies` also feeds the fixpoint at 879-884, where an
  overridden body runs as bytecode only if it is in `load_bodies`.
- `MrblibStubs.stubbable` (`tools/bc2cpp/mrblib_stubs.rb:64-65`): a body in `load_bodies` is kept with reason
  `runs at load` (`mrblib_stubs.rb:34`).

The function itself (`static_dispatch_registrations.rb:1125-1199`):

- **Roots.** `runnable` starts with every irep that has no enclosing method (`method_of` nil, line 1153): the
  root, class and module bodies, and the blocks written in them.
- **Receiver kinds.** `receiver_kinds` (1091) gives, for each send, the kind every reaching definition of the
  receiver register agrees on (`receiver_kind_at` 1105, `definition_kind` 1113-1123):
  - `[:const, Name]` for `GETCONST`/`GETMCNST` (1119), whatever the constant's value;
  - `:core` for any literal in `LITERAL_OPS` (1081-1082) or any `LOADI` (1121): an Array literal, a Range
    literal and an Integer all give `:core`;
  - `:self` for `LOADSELF`, and `:self` for R0 at entry; `:unknown` otherwise (a send result, a parameter, an
    upvar, or definitions that disagree).
- **Self kind** of each reached irep (1165-1169): `:class` for a root, a class body or a singleton method;
  `:core` for a core-owned instance method (`core` = not singleton and not `ENGINE_RE`, line 1085); `:instance`
  for an engine instance method. Core versus engine is decided by the owner's name, never by its file.
- **Targets** (1181-1188), matched by name (`by_name`) within a kind:
  - `:class`, `[:const, _]`, a literal Array-like kind: singleton or core owners;
  - `:core`: core owners only;
  - `:instance`: non-singleton owners;
  - `:unknown`, or `:self` resolved to `:class`: singleton or core owners, plus engine instance owners
    only when `engine_live` (1179).
- **Transitive closure.** A reached body queues every irep it owns (`irep_of_method`, 1152, 1190s): the
  body and its blocks.
- **Fallback.** If a load-time send may instantiate an engine class (`INSTANTIATING`, 1084: `new`,
  `allocate`, `load`, `_load`, `marshal_load`, with an unknown, instance or engine-owned receiver), the whole
  result is replaced by `load_phase_all_names` (1197, 1204-1220): the receiver-blind name cascade.
- **Result.** `[bodies, names]`. `names` is every name sent by a reached irep, whatever its receiver.

Two worlds read it, and they differ (see section 5):

- The analysis world is the engine's own mrblib (`closed_world`, `static_dispatch_registrations.rb:299-307`,
  `core_gems: nil`). Core mrblib is an outside source there.
- The stub world is the generation's sources, core and external mrblib included:
  `bc2cpp_closed_world_srcs` (`tools/bc2cpp/compiled_gems.rb:225-228`) calls `closed_world_mrblib_srcs`
  (`compiled_gems.rb:261-281`) with the build's gem list, and `bc2cpp.rb:2340` passes those `ireps` to
  `stubbable`.

## 2. What a receiver-aware version tracks

Per send, a receiver class set `S` (each element a class name) or *unknown*. `S` is computed from the same
reaching-definition query `receiver_kind_at` uses, with richer facts for each definition:

| Receiver fact | Source | Designed `S` |
| --- | --- | --- |
| `ARRAY`, `ARRAY2`, `ARYDUP`, `ARYCAT`, `ARYPUSH` | the literal | `{Array}` |
| `HASH`, `HASHADD`, `HASHCAT` | the literal | `{Hash}` |
| `RANGE_INC`, `RANGE_EXC` | the literal | `{Range}` |
| `STRING`, `STRCAT`, `SYMBOL`, `LOADSYM`, `LOADI*` | the literal | `{String}`, `{Symbol}`, `{Integer}` |
| `GETCONST N` | `BytecodeIR::ConstantFacts` class run: `groups[N].classes` (`tools/bc2cpp/bytecode_ir_constants.rb:24`, `analyze` at 91) | the constant's class, when every binding of `N` agrees and none is poisoned |
| `.freeze` of a literal or of such a constant | the freeze gate (`freeze_classes`, `bc2cpp.rb:636-639`) | the same class |
| a send result | a native method's proven return class (`native_return_classes.rb`, e.g. `Hash#keys` gives `Array`) | that class, else unknown |
| `self` | the self set of the enclosing method (below) | the classes reaching it |
| parameters, upvars, disagreeing definitions | none | unknown |

A constant whose value is a class (`Game::Actor`) keeps today's `[:const]` rule: a class receiver can
dispatch to singleton methods, so the change is only for values that are instances.

**Targets for a known `S`.** Owners `o` with `o` in `ClassWorld.ancestors(c)` for some `c` in `S`
(`tools/bc2cpp/class_world.rb:288`), matched by name. Singleton owners are added only when `S` holds a
class value. Any unknown element falls back to the current rule for that send.

**Self sets.** For each method body `B`, `selfset[B]` is the union of the `S` of every reached send that
targets `B`. A body whose set is unknown, or that is reached by any unknown send, keeps today's self kind.
When a set grows, the body's ireps are re-queued. The sets only grow and the classes are finite, so the
fixpoint terminates.

**Unchanged.** `names` stays the union of every reached send's name, whatever its receiver. A send on a
known Array still looks `each` up, so `each` stays a dynamic name for the registrations. Only `bodies`
narrows. The `engine_live` fallback stays as it is.

## 3. Soundness

**Claim.** At run time, a load-time send with receiver `v` dispatches to a body that is in the target set
computed for that send, and a body that runs at load has its `self` in its self set.

**Argument.**

1. *Receiver classes over-approximate.* Each definition's fact over-approximates the value it writes: literal
   classes are exact; a constant's class comes from the least fixpoint over its bindings in
   `ConstantFacts`, which poisons a name bound by a native or foreign definition
   (`bytecode_ir_constants.rb:16-18`, `IntegerConstants.native_defined_const_names` in `bc2cpp.rb:641-648`);
   return classes come from `NativeReturnClasses`, which admits a name only when every registration is
   accounted for. A register with more than one kind is unknown.
2. *Dispatch lands in an ancestor.* A call of `name` on an instance of `C` runs the first owner of `name` in
   `ancestors(C)`. The target set contains every body of `name` whose owner is in `ancestors(c)` for `c` in `S`,
   which contains that owner. Singleton owners are excluded for instances, which is sound because an instance
   has no singleton methods unless one was defined at load (see the risk below).
3. *Self is covered.* A method body is entered only by a send that reached it (its self set includes the
   receiver's `S`), or as root, class or block code, whose self is fixed by its own definition. Reflective
   entries (`CORE_REFLECTIVE_SENDS`, `static_dispatch_registrations.rb:432`) and the copying sends
   (`COPYING_SENDS`, `mrblib_stubs.rb:22`) make the body's self unknown.
4. *Unknown stays wide.* Any send whose `S` is unknown uses today's name-based rule, so the new kept set is a
   subset of the current one only where the argument above proves it, and a superset of the runtime set
   everywhere else.

**The one place it could fail.** Step 2 assumes the ancestor chain of `C` is the one the closed world
states. A module mixed into `C` at load (`C.include M`, `C.prepend M`, or a native `mrb_include_module`) adds
owners the chain does not show. `ClassWorld` marks a class *exact* only when every statement of every body
that opens it is one the file models (`tools/bc2cpp/class_world.rb:9-12`). The receiver rule must read the
ancestor chain only for exact classes; a class that is not exact gets the current name-based rule. A missed
`include` at load would otherwise drop a body that runs at load. That failure needs both a load-time mixin and
an inexact class, so the gate has to be part of the first implementation, not a later check.

Not part of this change, but relevant to the same proof: `engine_live` detects engine instantiation by the
name `new` (`static_dispatch_registrations.rb:1084`). A reflective instantiation (`send(:new)`) is not seen.
The closed-world lint (`docs/rpg2k-closed-world-lint.md`) is what keeps that out of the mrblib.

## 4. Where the new rule differs from the current one

Each row is a send (or a self) whose kept set changes. Rows A-E change targets; F and G do not.

| | Case | Today | Designed |
| --- | --- | --- | --- |
| A | Literal Array, Hash, Range or String receiver | `:core`: every core owner of the name | that class's ancestors only |
| B | Constant bound to a non-class instance (`EXTS = [...].freeze`) | `[:const]`: singleton or core owners | `Array`'s ancestors |
| C | Constant bound to a class (`Game::Actor`) | `[:const]` | unchanged |
| D | Send whose native return class is proven (`Hash#keys`) | unknown | that class |
| E | `self` in a body reached from a known receiver (`Enumerable#each_with_object` from a Range) | `:core`: every core owner | the reached classes |
| F | Parameter, upvar, disagreeing definitions | unknown | unchanged |
| G | `engine_live` fallback | `load_phase_all_names` | unchanged |

Measured with a scratch prototype in the source world (section 5), with kept bodies counted by
`Owner#name`:

- A and B alone: the kept set does not change (25 before, 25 after). The prototype confirmed this with a
  full set diff. The `each` sends that keep `Struct#each` and `Range#each` come from unknown receivers
  and from `Enumerable` self, which A and B do not touch.
- A, B, D and E together: the kept set goes from 25 to 17. It drops `Struct#each`, `Hash#each`, `IO#each`,
  `StringIO#each`, `Enumerator#each`, `Enumerator::Generator#each`, `Enumerator#__enumerator_block_call`
  and `Symbol#empty?`. `Range#each` stays kept, and the only remaining reason is the `Range` literal at
  `mruby-rpg2k/mrblib/game/lsd_io.rb:1143` (section 5).
- The same, with that one statement replaced in a scratch copy by a Hash literal: the kept set goes to 12,
  and `Range#each` is no longer kept.

Designed, not measured: that the self set of a method reached from a Range literal is `{Range}` (E); that
`ClassWorld` exactness gates the ancestor chain (section 3).

## 5. The load-time chains to `each` (measured)

`scripts/bc2cpp/load_phase_chain.rb --target each` prints every load-time send of `each` with its chain
(the call sites back to a root or class body). Source world, the stub generation's:

| Send | Where | Receiver | Reached from |
| --- | --- | --- | --- |
| `EXTS.each` | `mruby-rgss/mrblib/lib.rb:1163` (class body) | constant, an Array | root |
| `each` in `Enumerable#each_with_object` | `3rd/mruby/mrbgems/mruby-enum-ext/mrblib/enum.rb:599` (`self.each`) | self, reached from a Range | `mruby-rpg2k/mrblib/game/lsd_io.rb:1143` (`(0..11).each_with_object({})`) |
| `each` in `Hash#each_key` | `3rd/mruby/mrblib/hash.rb:90` (`self.keys.each`) | send result, unknown | `Hash#merge` at `3rd/mruby/mrblib/hash.rb:150` (`other.each_key`), called from `mruby-lcf/mrblib/schema.rb:1495` (`SAVE_MOVABLE.merge({...})`, a Hash constant; mrbc puts the send at line 1508) |
| `each` in `Struct#each` | `3rd/mruby/mrbgems/mruby-struct/mrblib/struct.rb:14` (`self.class.members.each`) | send result, unknown | `Struct#each`, reached by name from the send above |

Measured counts: 4 load-time `each` sends in the source world. After the `EXTS` loop rewrite (a scratch
copy with `while` in place of `EXTS.each`), 3 remain (`lsd_io.rb:1143`, `schema.rb:1495`, the `Struct#each`
cascade), and `Range#each` stays kept. The `EXTS` loop is part of `EXT_SPELLINGS` (`lib.rb:1161-1169`); the rewrite does not clear
`Range#each` because the other chains keep it.

**The closed build's own decision.** `build-closed-bc2cpp/closed/mrbgems/mruby-core-compiled/core_compiled_stubs.txt`
(56 entries) lists `Range#hash`, `Range#last` and `Range#overlap?`, and does not list `Range#each`. The
source-world kept set (25 bodies) and that manifest are disjoint. That agrees with the fixture's "today"
result, though it does not prove the kept set is exactly the build's.

**The load world is a second, larger cause (measured, with a caveat).** The stub generation reads original
sources. The closed build loads residual copies. In `build-closed-bc2cpp/closed/mrbgems/*/mrblib_stubs/`,
`LoadCompile` has moved the class-body statements out: `mruby-rgss/mrblib_stubs/mrblib/lib.rb` is blank from line
1146 on (the `EXTS` statements at `lib.rb:1161-1169` are gone), and `mruby-rpg2k/mrblib_stubs/mrblib/game/lsd_io.rb`
has no `SYSTEM_SFX_SAVE_FIELD`. The generated load code holds them instead: the constant name is in the load data
(`rpg2k_compiled_gen.cpp:130866`) and constants are set from decoded data (`bc2cpp_ld_decode`, line 131944). Running `load_phase_chain.rb
--world-list` over the residual copies (core files as in the source world) gives 53 load-time ireps, 2 kept
bodies (`IO.singleton#open`, `StringIO.singleton#open`) and **no** load-time `each`. Caveats: the residual copies
come from the build directory and were not regenerated from this tree; compiled load code (the C++ in
`*_compiled_gen*.cpp`, including its `bc2cpp_owner_call` and `mrb_funcall` fallbacks) is not analysed, so this
world is not yet a sound stub decision.

The residual result matters for the plan. With the receiver rule as designed, `Range#each` is still blocked
by `lsd_io.rb:1143` in the source world. Whether that statement is a real need depends on the load world the
stub rule reads, not on the receiver rule.

## 6. What remains before the implementation

1. Decide the load world for the stub decision: the source world (today) with `lsd_io.rb:1143` changed, or the
   residual world plus compiled load code. The second needs a scan of the generated load code's dynamic
   sends, and its own soundness argument. It is a bigger change than the receiver rule.
2. Implement the receiver rule (A-E) with the `ClassWorld` exactness gate (section 3), `names` unnarrowed,
   and the `engine_live` fallback unchanged.
3. Make `scripts/bc2cpp/load_phase_receiver_check.rb` pass. It is registered as deferred in
   `scripts/ci/bc2cpp_check_policy.yml`, so the registry check passes. The implementation commit moves it to
   `checks` (tier `fast`, `capabilities: [mrbc]`) and adds `ruby scripts/bc2cpp/load_phase_receiver_check.rb`
   to the `bc2cpp-build` job, next to `super_optional_check`.
4. Add a control to the fixture for the `lsd_io.rb:1143` shape (a Range receiver whose `each` must stay kept).
