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
Arguments, self, ivars, constants, calls and overloaded arithmetic remain
unknown. Exception-flow propagation and trusted call summaries are future
extensions. This first layer is available for analyses; generated code does
not yet consume it. See [ADR 0440](adr/0440-bc2cpp-ir-value-types.md).

Run `ruby scripts/bc2cpp/bytecode_ir_check.rb` for the type-query regression
checks, alongside the existing reaching-definitions checks.
