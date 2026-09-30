# 0287. bc2cpp: a return-class table and an exact-class flow drop the guard of TYPED calls

Date: 2026-09-30

## Status

Accepted

## Context

`x = foo(...)` then `x.bar` is the commonest receiver shape the compiler cannot resolve without a
run-time class test. Three facts were already computed and each stops short of it:

- `class_return_names` (ADR 0194, 0236) says every definition of `foo` returns an instance of one
  class, but it is a `ClassLayout`-style hint: the consumer emits `TYPED`, a direct call behind an
  `mrb_obj_class` test with a dynamic send as its else.
- `NUMERIC_RETURN_PROOF` (ADR 0276) joins the classes every definition of a name returns, but its
  lattice stops at Integer, Float, Array, Hash, String and nil, and `NumericFlow` refused any irep with
  a catch handler, so a method with `rescue` had no facts at all, and a block's `return` made the
  whole method opaque.
- `EXACT_CORE_RECEIVER` and `CLOSED_WORLD_EXACT_CLASS` (ADR 0280, 0198) take a receiver that is
  provably exact, but only through a dominating literal or a `Klass.new` in the same method. ADR 0280
  measured a receiver-sensitive return table for core methods and left it out: 8 of 158 `send_result`
  receivers, none of which removed a site.

Measured on the wio closed world before this change (`scripts/bc2cpp_coverage_report.rb`): 492 `TYPED`
arms (each a guard, a direct call and a fallback block that repeats the native-direct arms), 10,597
cached dispatch sites, 2,919 guarded arithmetic arms ending in a send.

## Decision

### 1. NumericFlow models catch handlers, Range literals and block returns

`NumericFlow.states` no longer refuses an irep with a catch handler. Every instruction of a protected
range gets an edge to the handler's target (`BytecodeIR::Program#handler_edges`) carrying the state
before the instruction, widened the way a callee can widen it: a call clobbers every register from its
own up and every ivar slot is reset to its whole-program fact (`raise_state`). `EXCEPT` writes an `EXC`
(pending exception) mask, nil as well only where an `ensure` can be entered without a raise; `RESCUE`
writes its second register; the fall-through edge of `RAISEIF Ra` keeps only what may be nil, so an
unmatched rescue clause, which always re-raises, contributes no value. The rest of the table was already
there. An irep the flow still cannot model (a `JMPUW`, two in the closed world) keeps answering nil.

`RANGE_INC`/`RANGE_EXC` give a new `RNG` bit (exactly `Range`). `NumericFlow::OPAQUE` names the bits a
fact that crosses a method (pooled argument, ivar, constant) may not carry, so `RNG` and the class bits
below behave like `OTHER` there and nothing that was numeric changes.

`numeric_return_def_mask` joins the `RETURN_BLK` of every block nested in the method (a `return` inside
`each { }`) instead of giving up. A `break` is the result of the call that took the block, which
`SENDB` never reads, so it adds nothing; a lambda's own `RETURN_BLK` is counted too, which can only add
classes.

### 2. RETURN_CLASS_TABLE: a second run of the flow whose oracle knows nothing outside the method

`tools/bc2cpp/codegen_return_classes.rb` runs `NumericFlow` again with `ExactOracle`:

- entry arguments, ivars on entry and after any call, constants and captured locals are unknown (the
  pooled facts of ADR 0276 fail safe on a wrong number; here a wrong class is an unchecked direct
  call, so they are not used);
- a SEND of `new` is the class bit of `Klass` when `exact_new_class_at` proves a fresh standard
  construction of a class whose constant and constructor chain are closed-world stable (the proof
  `compile_send` already trusts for `CLOSED_WORLD_EXACT_CLASS`), one bit per class, allocated on first
  use (`CLASS_BIT_BASE`); Array, Hash, String, Range and the numeric classes keep their own bits;
- a SEND of a name in the table is the set the table holds.

The table maps a name to the join, over every definition in the registry, of the classes its
`RETURN`/`RETURN_BLK` sites can hold, as a least fixpoint: each name starts empty, sets only grow, a name
that reaches `OTHER` (anything unmodelled: a yield result, `super`, `self`, an argument, an ivar, a
boolean, a Symbol) is dropped for good, and the flows of the ireps that call a name whose set changed
are recomputed. Recursion proves itself the way the base case does. Names are admitted exactly as
`NUMERIC_RETURN_PROOF` admits them (`numeric_return_candidates`): not defined or spelled by a native or
foreign source, not renamed by `alias`/`alias_method`/`define_method`, no `method_missing` anywhere, no
native definition, no global refusal. A name with a second definition in another class, a prepended
module or a singleton copy joins their returns, so one that returns another class ends the exactness.
The whole table needs `ClosedWorld#exact_instances_singleton_free?` (ADR 0280): "made by the literal"
means "exactly that class" only while nothing can give the object a singleton class.

`exact_flow_class(irep, idx, reg)` answers the one class a register holds at an instruction, from the
flow state, or nil when the set is empty, mixed, or contains nil.

### 3. Consumers

- `exact_core_value_class` falls back to the flow for Array, Hash, String and Range receivers, so the
  ADR 0253/0257/0270 arms drop their class test for `xs = build_rows; xs.join`.
- `compile_send` takes the flow's class as `exact_class` when the `Klass.new` walk has none (and, like
  the record-hash proof of ADR 0285, treats it as a fresh instance).
- **EXACT_TYPED.** A `TYPED` arm (and the `IVAR_ACCESSOR` arm) whose guard class is the receiver's proven
  exact class emits the direct call with no guard and no fallback. The guard can only be true, and it
  never protected against anything else: `mrb_obj_class` skips singleton classes, so a singleton
  override was already invisible to it. `CLOSED_WORLD_EXACT_CLASS` could not take these sites because it
  needs `inherited_lookup_safe?`, which every name an outside native also spells (`z=`, `x=`,
  `update`, ...) fails; the TYPED target is the registry definition the class itself owns, so that gate
  does not apply.

## Consequences

Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb`, the shipped build), `master` at
`fa5ced1f` against this branch:

| | before | after |
| --- | ---: | ---: |
| cached `bc2cpp_send`/`mrb_funcall_with_block` sites, guarded fallbacks included | 10,597 | 10,383 |
| `TYPED` calls behind a class guard with a send fallback | 492 | 246 |
| `EXACT_TYPED` guard-free direct calls | 0 | 246 |
| arms whose send NUMERIC_OPERAND_PROOF removed | 353 | 360 |
| guarded arithmetic/compare arms still ending in a send | 2,919 | 2,912 |
| `BLOCK_CORE_DIRECT` arms narrowed to the proven class | 13 | 21 |
| `NOMETHOD_REVIEWED` dead-fallback entries (they went with the fallbacks) | 3,379 | 3,120 |
| names with one exact class in the table | n/a | 195 |

Where the 214 fewer cached sites come from:

- 150 are the consumer alone: `TYPED` arms whose receiver was already a fresh `Klass.new` or a
  record-hash read (proofs that existed and were only used by `CLOSED_WORLD_EXACT_CLASS`) now drop the
  guard (492 to 278 guarded, 214 guard-free). That part does not depend on the table. It is here because
  the table has no other way to matter: for the names an outside native also spells (`z=`, `x=`,
  `update`, ...) `CLOSED_WORLD_EXACT_CLASS` is unavailable.
- 64 come from the flow: a class that reaches the receiver through a call (`x = foo(...)`), a rescue
  path, a block `return` or an ivar slot stored and read before any call (`@w = Window.new; @w.z = 1`)
  (278 to 246 guarded, 8 more narrowed block arms).
- 7 numeric arms come from the handler and block-return modelling (`rescue` methods now have facts).

The table is worth far less than the numbers suggest, and this should not be oversold: 32 of the 246
guard-free sites, 8 block arms and 7 numeric arms are its own contribution. Most receivers that stay
guarded come out of an ivar on entry, a parameter, a `GETIDX` or a core block method (`map`, `select`
are `alias`es in `enum.rb` and `SENDB` results), which are whole-program facts this table deliberately
does not use; the producers of unresolved receivers are mostly natives and core methods (`char`, `find`,
`keys`, `now`, `dup`, `class`, `to_s`). Pooled ivar and argument classes could reach more sites but
would put a scan-based claim behind an unchecked direct call, which ADR 0276 did not need to do for
numbers. A method with `ensure` has no exact return (the exceptional path joins the normal one); there
are two in the engine.

Checked by `scripts/bc2cpp_return_class_check.rb`: generated code for thirteen exact shapes (local, call,
chain, forward, recursion, rescue, block `return`, ivar slot, subclass result, inherited target, copy,
and the two that only `EXACT_TYPED` can take), eleven guarded ones (two classes, nil, parameter, ivar on
entry, slot after a call, yield, reassignment, branch join, captured write, ensure, two classes behind an
`update`-like name) and each way of losing the proof (alias, `define_method`, second definition,
prepended module, `method_missing`, singleton `make_box`, redefined `new`, `singleton_class`,
`instance_eval`, a def on an object, the open world); and, with a full-core mruby, the compiled fixture
answers what the interpreter answers for every method, including the receivers a wrong proof would
mis-dispatch. `scripts/bc2cpp_numeric_operand_check.rb` covers handler edges, `EXCEPT`/`RESCUE`/`RAISEIF`
and Range on hand-built bytecode, and `rescue`/block-`return` methods against the interpreter.
`scripts/bc2cpp_include_ancestor_check.rb` now expects the guard-free call for a fresh receiver.

Residual risk: the table and the class bits trust the closed-world scan (`name_fully_visible?`,
`stable_standard_constructor_class?`, `exact_instances_singleton_free?`) as ADR 0280 and 0258 do; a
native gem that creates a singleton class or defines a name through a spelling the scan does not know
would make a direct call wrong with no guard. `EXACT_TYPED` also takes the fresh-`Klass.new` receivers
that were only guarded before; those proofs never required `exact_instances_singleton_free?`, and the
removed guard (`mrb_obj_class`, which skips singleton classes) did not protect against a singleton
override either. The handler edge model over-approximates (every instruction of a range may raise),
which only costs proofs. Nothing ran a 32-bit `mrb_int` build: no mask or constant here reaches an
`mrb_int`.

## Addendum: one `direct_callable?` predicate

Five sites of `compile_send` (module-function self, lexical self, exact target, TYPED candidate,
inherited target) each spelled "has a bytecode body, the direct convention carries its signature, it
compiles without an `#error`, and the argument count fits". They are now `direct_callable?(definition, n)`,
in that order, because `compiles_clean?` compiles the callee and must not run for a signature a direct call
cannot express. It is a pure refactor: the shipped output and the diagnostic of the wio game build and of
optcarrot are byte-identical before and after (`cmp` of the generated C++ and of stderr). The MONO gate,
the diagnostic reason codes of `poly_arity_fits?`/`cha_self_reason`, the constant-object and keyword
paths keep their own wording: they differ in order, in the `compiles_clean?` step or in the reason they
report, so folding them in would not have been identical.
