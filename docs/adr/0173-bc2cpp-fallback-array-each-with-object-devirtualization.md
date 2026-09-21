# 0173: Carry Array element types into fallback each_with_object blocks

Date: 2026-09-21

## Status

Accepted

## Context

Fallback block cfuncs can retain a proven Array element class for `each` and
`each_with_index`, but `Array#each_with_object` also exposes the receiver's
element in a fixed block argument position. mruby's implementation forwards
the element first and the accumulator second.

## Decision

Extend fallback element specialization to `each_with_object` calls with one
explicit accumulator argument and exactly two mandatory block parameters.
Reuse the existing Array and element proofs, and hint only the first parameter.
Keep the exact runtime class guard and ordinary Ruby dispatch fallback.

## Consequences

Proven elements can use guarded direct dispatch in fallback
`each_with_object` blocks. The accumulator, unknown elements, other iterator
shapes, and non-Array receivers remain dynamic. The whole-program report
currently finds no additional guarded production call sites for this shape;
the regression check covers typed and untyped receivers, including the
`Game::Troop#drops` block shape.
