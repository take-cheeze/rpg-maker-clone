# 0375. bc2cpp: class narrowing by the runtime test that dominates a use

Date: 2026-10-07

## Status

Accepted

## Context

A receiver's class set is proven by the exact-class flow (`NumericFlow`, ADR 0276/0289), the class pools (ADR 0296),
the receiver unions (ADR 0348, 0352) and the post-call facts (ADR 0317). The flow already narrows by truthiness
(`JMPIF`/`JMPNOT`/`JMPNIL`: `x` is not nil in `if x`, `x.nil?` in a condition is a `JMPNIL`), and ADR 0293 compiles
`is_a?`, `kind_of?` and `===` to direct C calls. Nothing connected the two: the answer of a class test never changed
what the flow knew about the variable it tested, so `if x.is_a?(Foo); x.bar; end` dispatched `bar` through the same
chain as an unguarded `x.bar`. ADR 0317 says so (the flow "has no is_a?/respond_to? narrowing and no post-call narrowing").

What was handled before this change, by form:

| Form | Before |
| --- | --- |
| `x` / `unless x` / `x ? a : b` (truthiness), `x.nil?` as a condition (`JMPNIL`) | narrowed the nil bit on each edge (existing) |
| `x.nil?`, `!x`, `x.is_a?(C)`, `kind_of?`, `instance_of?`, `C === x`, `case x when C`, `x.respond_to?(:m)`, `x.class == C` as a value | not narrowed |
| `x.m1` then `x.m2` | CALL_FACTS (ADR 0317) bounds the receiver of `m2` by the classes answering `m1`; unchanged |
| a receiver that is nil or one class | NILABLE_RECEIVER (ADR 0296): the non-nil arm is exact; unchanged |
| `raise ... unless test` | not narrowed: the flow let `raise` return |
| `a \|\| b`, `a && b` in a condition | not narrowed: the second branch is a branch on the register the first one tested, and the join threw the narrowing away |

## Decision

CLASS_NARROWING is occurrence typing for the exact-class flow. Everything is in the flow, so every consumer of a class
set (exact core arms, receiver unions, NILABLE_RECEIVER, native wrappers, the Fixnum proof, guard chains, dropped else
arms) sees the narrowed set with no change of its own: a proven set drops the else arm or the whole chain, a
scan-complete set ends in `bc2cpp_nomethod` / `bc2cpp_guard_violation`, an unproven one keeps the by-name send.

1. **A test is a fact about a register.** `NumericFlow` keeps, next to the masks and the provenance, one more column
   of `nregs` entries: the test whose boolean the register holds. A `SEND`/`SEND0` the oracle recognises
   (`CodeGen#class_test_for`, `tools/bc2cpp/codegen_class_narrowing.rb`) records, in its result register, the
   *variables the subject was a copy of when the call started* (the chain: the argument of `case x when C` copies the
   case temporary, which copies `x`; a call clears the provenance, so it is read before the call) and the predicate.
   A `MOVE` copies the entry (`ok = x.is_a?(C); ok ? ... : ...`). `JMPIF`/`JMPNOT` on a register that holds a test
   narrows every variable of the chain on each edge with the predicate.
2. **Predicates** (`CodeGen::ClassTest`). `kind_of` (`is_a?`, `kind_of?`, `C === x`), `instance_of`
   (`instance_of?`, and `x.class == C` through the class-of register, below), `nil` (`nil?`), `falsy` (`!`),
   `responds` (`respond_to?(:m)`). A predicate answers per exact class: passes, fails, or no verdict. On an edge the
   bits that fail are dropped; a bit with no verdict (OTHER, an exception, a runtime-checked pool bit, a class the world
   does not pin down) passes both edges. On the edge where the test holds, OTHER is replaced by the exact set of
   instances that pass when the world proves it (`class_test_positive`): the class and its declared descendants for a
   declared class (at most 16, `ClosedWorld#class_hierarchy`, no wild or opaque member), the one bit of a core class
   whose subclasses the world rules out (`native_subclass_free?` plus a scan of the native sources for a
   `mrb_define_class*` with the class as its superclass), `nil` for `nil?`, every class that may answer the name for
   `respond_to?` (`CallFacts::Answers#members`, only when each has a bit). Modules are not tests this change narrows by.
3. **Branch joins.** `a || b` and `a && b` in a condition compile to a branch on the register of the first test
   followed, at the join, by a second branch on the same register. An edge out of a branch on a test boolean into
   another branch on that register is carried to the successor the boolean decides (`thread_class_test`), so the
   narrowing is not joined away with the path that tests again. Complements and merges after `if/else`, `case`, `?:`,
   early `return`/`next`/`break` and `raise` need nothing more: the flow's join is the union of the edges' sets.
4. **`raise` does not return.** With Kernel#raise (kernel.c `mrb_f_raise`) the only definition of `raise` in the world,
   the flow gives an implicit-self `raise` no normal successor, so `raise X unless x.is_a?(C)` narrows `x` for the rest
   of the method (the handler edges are unchanged).
5. **Calls keep register copies.** Without this the copy chain of `case x when A, B` is lost at the first `===`. In
   narrowing mode a call forgets the slot copies and the copies of the callee's frame only; a call cannot write a local
   no block captures. A constant lookup no longer forgets the ivar copies when no `const_missing` exists
   (`const_missing_free?`), so `if @x.is_a?(C)` survives the `GETCONST` of its argument.
6. **`x.class == C`.** `SEND0 class` (Kernel#class only) records a class-of entry; an `EQ` of it and a class constant
   becomes the `instance_of` test. It needs `==` on class objects to be identity: no Ruby definition on Module, Class,
   Object, Kernel or any `.singleton`, none installed by name, no module mixed into them.

### Soundness

| Rule | Where it is enforced | Negative case in the check |
| --- | --- | --- |
| The variable is rewritten between the test and the use | `set` clears the entry of the register and every test aimed at it | `neg_reassign`, `neg_loop_swap` (back-edge) |
| A block that may run writes the variable | the variable is a captured register (`opaque`): never narrowed | `neg_block_write` |
| A call may write an ivar, a global or a callee-visible slot | a call forgets the tests aimed at slots; globals have no slot | `neg_call_between`, `neg_global` |
| The handler of a `rescue`/`retry` runs with an older value | a handler edge joins the state before the raising instruction | `neg_rescue` |
| Two paths join and only one tested | a join keeps a test entry only when both sides hold the same one | `neg_join_test` |
| The test of another variable | the entry names its own chain | `neg_other_var`, `neg_or_other` |
| A user `is_a?`, `kind_of?`, `instance_of?`, `===`, `nil?`, `!`, `respond_to?`, `class`, or a Ruby definition of `==` on class objects | `class_test_name_safe?` (registry holds only the kernel.c/object.c/class.c natives, no outside Ruby, no unknown definer), `eqq_direct_safe?`, `class_object_eq_safe?` | one world per name |
| An alias, undef or computed `define_method` of the name | `name_unrebound?` (`symbol_installed_names`, nil when a name is computed) | `alias of is_a?`, `a definition from a computed list`, `an alias of facet` |
| A BasicObject subclass (its `is_a?` is a `method_missing`) | `kernel_native_dispatch_safe?` | `a BasicObject subclass` |
| A singleton, `extend`, `Class.new`/outside subclass of the tested class | `exact_instances_singleton_free?`, `class_hierarchy` (nil for an opaque class) | `an instance with a singleton method`, `a dynamic subclass`, `an outside source subclasses` |
| A subclass of Array/Hash/String/Integer/Float/Range/Numeric | `native_subclass_free?` and the native-source scan | `a subclass of Array` |
| `respond_to_missing?` or a name installed from outside | `respond_to_missing_absent?`, `CallFacts::Answers#definers` is nil for an unbounded name | `a Ruby respond_to_missing? definition`, `an alias of facet` |
| `Class.new`/a module mixed into Class changes `new` | the exactness of `.new` (ADR 0313) is the base of the narrowed sets, unchanged | `a module mixed into Class` |
| The proof is wrong anyway | the run-time guard below | the rogue-subclass run |

### Run-time guard

Where a test narrows its subject, the compiled code checks after the test, in the generated C++, that the class of the
subject is in the set the proof assumes on the edge the test took: a member of the narrowed set when it names only
classes, else not a member of the classes the narrowing dropped. A violation is `bc2cpp_guard_violation`
(`(CLASS_NARROWING)`, ADR 0290): `BC2cppGuardViolation` with the log line, an abort under `-DBC2CPP_NOMETHOD_VERIFY`,
and the dispatched answer under `-DBC2CPP_GUARD_VIOLATION_DISPATCH`. A wrong closed-world fact (a class nobody could
see) therefore fails at the test and not as a call into the body of another class. The guard needs the violation
helper, so `BC2CPP_GUARD_VIOLATION=0` also turns narrowing off.

### Switches

`BC2CPP_CLASS_NARROWING=0` turns every part off: the generated code is the master code, byte for byte.

## Consequences

RESULTS

Not built:

* `x == nil` / `x != nil`: `Comparable#==` is a Ruby `==` of mruby's own, so no build has an exact `==`; the engine
  spells `.nil?` (403 sites) and `== nil` (0).
* `x.class.equal?(C)`, `x.class === y`, `C == x.class`, `x.is_a?(Module)`: no engine site, and modules need the
  includers of the module, which `CallFacts` bounds only through `members`.
* Narrowing the globals and the elements of containers: nothing proves a global or a slot of a container unwritten.
* The else edge of `respond_to?` (the classes that definitely respond): visibility is not modelled.
