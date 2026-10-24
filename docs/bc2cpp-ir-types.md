# Bytecode IR value types

`BytecodeIR::Types.new(irep).at(index, reg)` returns a frozen Set of possible
value classes (symbols such as `:Integer` and `:NilClass`) at a register read.
The index is an instruction index; the register is its number as digits.
It returns `nil` when any reaching value is unknown or the dataflow refuses.

```ruby
analysis = BytecodeIR::Types.new(irep)
reason = {}
types = analysis.at(return_index, '2', refusal: reason)
# A branch assigning 1 or nil gives Set[:Integer, :NilClass].
# An unknown assignment on either branch gives nil, never a partial set.
```

The initial analysis classifies immediate and pool literals, fresh Array,
Hash, Range and Proc producers, and ENTER-created rest, keyword hash, block
and cleared local slots. Shared reaching definitions follow MOVE chains,
merge branches and loops, and account for nested-block writes. Unresolved
control flow, protected instructions, unknown producers, callee clobbers,
unreachable reads and state-budget exhaustion keep the answer unknown.
`max_states:` sets the existing dataflow query budget; `refusal:` receives its
first refusal cause or the unknown producer opcode.

These are value classes, not exact method identities, finite literal values,
container element types or machine representations. `:Integer` includes
big integers on 32-bit targets and cannot justify unchecked native arithmetic.
The inference-only query leaves arguments, self, ivars, constants, calls and
overloaded arithmetic unknown unless an independently audited call fact is
supplied. [Call-result propagation](bc2cpp-ir-call-results.md) connects the
compiler's settled proofs and nominal receiver contracts to this layer. This first layer is available for analyses; generated code does
not yet consume it. See [ADR 0440](adr/0440-bc2cpp-ir-value-types.md).

Run `ruby scripts/bc2cpp/bytecode_ir_check.rb` for the type-query regression
checks, alongside the existing reaching-definitions checks.

## RBS argument contracts

The RBS loader retains nominal value-class bounds for `T?`, unions, `bool`,
`nil`, literal types, named classes and the outer classes of Array/Hash
parameters. A union containing `untyped` or any unsupported member remains
unknown. Generic element types and literal values are not inferred from this
projection. Required arguments, ivar reads and implicit self-call return contracts seed
IR queries; inherited contracts use the program hierarchy.

After `RbsSignatures.apply` has matched definitions and checked required arity:

```ruby
analysis = RbsSignatures.ir_types(applied_signatures, irep)
fact = analysis.fact_at(return_index, '2')
# fact.classes is a frozen Set; fact.declared? records reliance on a contract.
# analysis.at(return_index, '2') still answers only from inferred definitions.
```

Contracts apply to entry values and the first argument rebound by ENTER,
then follow the shared MOVE, branch and loop analysis. Ordinary explicit
receiver calls also resolve return contracts through known nominal bounds. They do not override
later writes or bypass handler, closure or clobber refusals. Comment-owned
parameter slots are excluded from RBS seeds. The low-level `declared_args:`
constructor option accepts required parameter registers only.

A declared fact is conditional on callers honoring the signature and names
nominal bounds, including subclasses. It cannot justify an exact receiver
class, method identity or unchecked native representation. Any union that
uses a declaration remains marked declared, even when other definitions are
inferred literals. Runtime dispatch still uses the existing proofs and guards.
The type-check report presents these bounds with source `signature`.
[IR feedback](bc2cpp-ir-feedback.md) adds return/ivar compatibility diagnostics
and reviewable inferred RBS suggestions; optimization hints are unchanged.
See [ADR 0441](adr/0441-bc2cpp-ir-rbs-contracts.md).

## Exact-class refusals

`Types#exact_at` is the literal-only exact-class proof that generated code
consumes (exact receivers, `===`, `times`, step loops). Like `at`, it accepts
`refusal:`, a Hash that receives the first reason the proof failed:
`producer:<OP>` for a reaching writer that is not a literal, `entry:<slot>` or
`entry_value` for an entry value, `self_unknown` for R0 or `LOADSELF` without
the caller's `self_class`, `class_join` when the definitions disagree,
`container_mismatch` for a container op over another class, and the dataflow's
own causes (`state_cap`, `query_guarded`, ...). The cause is diagnostic only:
the answer and its cache are the same with or without it. Run
`ruby scripts/bc2cpp/ir_facts_check.rb` for the fixture checks.
