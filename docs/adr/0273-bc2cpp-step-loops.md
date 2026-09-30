# 0273. bc2cpp: inlined step loops

Date: 2026-09-30

## Status

Accepted

## Context

`Integer#step`, `#upto` and `#downto` were block calls even with literal bounds, so a loop such as
`341.step(589, 8) do ... end` cost a Proc, a dispatch and a call per iteration and kept its body out
of the method's frame. `#times` has been inlined since ADR 0147; a later change needs loops of this
shape to stay in one function frame (ADR 0273 continues with Fiber roots).

## Decision

### Inlined `Integer#step` / `#upto` / `#downto` (STEP_LOOP_SUPPORT)

`recv.step(limit, step) { |i| }`, `recv.upto(limit)` and `recv.downto(limit)` join the inlined
loop passes (`INLINE_LOOP_PASSES`) when the receiver and limit are provably Integers and the
`step` of `#step` is a non-zero literal. Proof is a `LOADI` literal with no jump between it and
the call, or `proven_fixnum_operand?` (FIXNUM_OPERAND_PROOF). Anything else (Float operands,
`Range#step`, a computed step, no block) keeps the block call, which also keeps the
`ArgumentError` for a zero step and the Float semantics of mrblib's `Float#step`. The loop is
mrblib's `while i <= num` (`>=` for a negative step) over a `long long` counter, so `i += step`
cannot wrap a 32-bit `mrb_int` (the bounds are fixnums), and it returns the receiver.

## Consequences

- Loops over literal or proven-fixnum bounds run as native `for` loops; the only observable
  difference is the missing block frame, as for every inlined loop.
- `mruby-lcf`'s `7.downto(0)` in `LCF.unpack_double` is now inlined.
- Verification: `scripts/bc2cpp_step_inline_check.rb` compiles a fixture, links it into a
  full-core mruby and requires the compiled run to print what the interpreted run prints.
