# 0500. NumericFlow reads its instruction facts from the bytecode IR

Date: 2026-10-19

## Status

Accepted

## Context

NumericFlow (ADR 0276) is the forward class-mask flow behind the unguarded
numeric arms, the return-class pools, the block, core-Ruby and contextual
results. ADR 0467 moved its edges, handler targets and decode onto
`BytecodeIR::Program`, but it still read the raw `irep.instructions` for the
rest: the second register and ivar operands of each op, the literal-element
proof (ADR 0354, a backward scan of at most 32 instructions), and each
consumer folded its return mask by scanning the raw list for `RETURN`-family
ops. The IR's reaching definitions and type layer already answer the questions
those scans approximate.

The flow itself stays a forward abstract interpretation: its facts are
path-sensitive (truthiness and class-test narrowing on branch edges, ivar slots,
handler states), which the IR's per-query reaching definitions cannot express
without losing those proofs.

## Decision

`tools/bc2cpp/bytecode_ir_numeric.rb` adds the IR facts the flow reads:

- `Program#operands`: per instruction, the second register (`MOVE`'s source,
  an operator's parenthesised operand, `GETIDX0`'s receiver, `RESCUE`'s flag,
  `SETIV`'s value) and the ivar name. The flow's Step table is built from
  `Program#decoded` and `Program#operands` only.
- `Program#exits` with `NumericClasses.exit_mask`, `.returned_mask`,
  `.block_return_mask` and `.block_returns?`: the frame exits and the joins over
  the reached ones, which replace each consumer's raw `RETURN` scan. Every
  consumer runs the flow through `NumericClasses.states`.
- `Program#linear_corridor?`, shared with the contextual frozen-table shape.
- `NumericClasses.element_literal_mask`, the literal-element proof on reaching
  definitions: the read's receiver has one reaching write, an `ARRAY`/`ARRAY2`
  followed only by quiet ops on a linear corridor; the key is one integer
  literal; and every definition of the element's register reaching the `ARRAY`
  is a literal whose class the type layer names
  (`BytecodeIR::Types.literal_class`). It replaces `LiteralElementProof`.

The switch was opt-in (`BC2CPP_IR_NUMERIC_FLOW=1`, with
`BC2CPP_IR_NUMERIC_COMPARE=1` logging every Step and element disagreement)
while the engine's facts were compared; it is gone now, and the raw decode and
`literal_element_proof.rb` are removed.

The op_native?/nil_raises? gates stay where the flow applies them: they are
oracle questions about the closed world, not instruction facts.

## Consequences

- No numeric analysis walks `irep.instructions` itself; the instruction a
  question is about reaches the oracle as the IR instruction's source.
- The element proof admits more: a literal written any distance before the
  `ARRAY` (through calls that cannot clobber it), joins of literal arms, moved
  literals, Float/Hash/Range literals and pool constants. The `ARRAY`-to-read
  corridor is no wider than before in kind (quiet ops only), so freshness is
  unchanged. `BC2CPP_LITERAL_ELEMENT_PROOF=0` still withdraws it.
- The flow's oracles (NumericOracle, ExactOracle, the core-Ruby and contextual
  oracles) still read their own operands of the instruction they are asked
  about; moving them is separate work.
