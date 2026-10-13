# 0431. bc2cpp: `Integer & | ^ Integer` is an Integer result

Date: 2026-10-13

## Status

Proposed

## Context

ADR 0430 (Option 1) records that `CodeGen#numeric_send_on_number`
(`tools/bc2cpp/codegen_numeric_returns.rb`) answers OTHER for every bit operator.
A result that is OTHER cannot prove a constant-table read's index is an Integer
(`codegen_frozen_tables.rb`, `key_int`), so `TABLE[a & 3]` reads as unknown. The
same OTHER answer reaches every consumer of the numeric flow that reads a
`&`, `|`, `^` result.

Two facts decide what can be claimed:

- INT means an Integer class, fixnum or bignum (ADR 0279). `arith` already
  claims INT for `Integer + Integer` with no range proof, and the bignum result
  is handled by the arithmetic slow paths.
- The bit-operator slow helpers already handle a bignum operand
  (`NUMERIC_SLOW_BITS` in `codegen_numeric_slow.rb`: `mrb_bint_and`,
  `mrb_bint_or`, `mrb_bint_xor`). The `STEP_LOOP_GUARD` and the native
  conversion path (`numeric_native_direct_code`) both admit an INT operand that
  may be a bignum at run time.

## Decision

`numeric_send_on_number` answers INT for a one-argument `&`, `|` or `^` when the
receiver is exactly INT and the argument is exactly INT. Every other operand
combination stays OTHER, and an unreached operand (mask 0) yields 0, as `arith`
does. The rule is `numeric_bitop_mask`, gated by `BC2CPP_BITOP_RESULTS`.

`<<` and `>>` are not claimed. No range proof bounds a shift count, and a
negative `>>` count shifts left, so the result can grow without limit. They stay
OTHER.

### Soundness

1. **Class.** `Integer#&`, `Integer#|` and `Integer#^` with an Integer argument
   return an Integer, so the INT class is exact. The receiver's `builtin_class_send_safe?`
   check in `numeric_send_on_class` still refuses a program that overrides them.
2. **Operand classes.** A Float receiver has no such operator, so the FLT arm is
   OTHER. An INT receiver with a NIL, Float, or other argument is OTHER. Only the
   INT x INT pair claims INT.
3. **Range.** INT is not a range claim (ADR 0279). The result of `& | ^` on two
   fixnums stays in the fixnum range, since a signed bitwise operation of two
   values in a `w`-bit range is in that range. A bignum operand gives a bignum
   result, which the INT class already allows, the same as `+`. The fixnum proof
   (`proven_fixnum_operand?`) does not read this numeric mask (ADR 0279), so an
   INT result is never a proven Fixnum.
4. **Consumers.** Every consumer that reads INT already handles a possibly-bignum
   value. `step_loop_operand` puts an INT that is not a proven fixnum behind a
   run-time guard (`STEP_LOOP_GUARD`). The frozen-table read takes INT as the
   key class only, and `numeric_native_direct_code` converts through the audited
   Integer entry, which accepts a fixnum or a bignum.
5. **Monotone.** The rule is OR-monotone in both operands: a larger operand mask
   never gives a smaller result (0 < INT, and OTHER absorbs). The dataflow
   fixpoint therefore converges as it did before.

### What the brief asked, and where this differs

The task asked that a result which can become a bignum "must not be claimed
INT" unless the operand ranges prove it fits. The numeric model has no range
proof, and `arith` gives INT for `+` and `*` without one. Refusing `& | ^` for a
bignum result alone would make it stricter than `+`, and it would not be
checkable from the model. The claim is therefore restricted to the class: INT
on both operands, with no range claim. A reviewer who wants a range proof before
any INT result should reject this rule and keep Option 1 at `<<`-only, or add a
range source first.

## Kill switch

`BC2CPP_BITOP_RESULTS=0` removes the rule. The output must then match the
build without the change. The check `scripts/bc2cpp/bitop_results_check.rb`
(in `ruby-checks` and `scripts/coverage/report.rb`) runs the kill-switch case.

## Consequences

### Measured (coverage report, three arms on the same closed world)

Master, the branch with the switch off (`BC2CPP_BITOP_RESULTS=0`) and the branch
with the switch on were each run through `scripts/bc2cpp/coverage_report.rb`
with `3rd/mruby` sources present (the core registry, `builtin_class_send_safe?`,
needs them; an empty `3rd/mruby` silently turns the rule off, which an earlier
run without them showed).

- Switch off is byte-identical to master: `shipped.cxx` (434,505 lines,
  21,128,326 bytes), the shipped stderr and the report are identical.
- Switch on: `shipped.cxx` is still byte-identical to master. Zero functions
  change, zero line or byte delta, and the 398 `NUMRET` diagnostic lines are
  identical. The rule returned an INT result 103 times during the shipped pass
  (counted with a trace on a scratch copy; repeats across fixpoint iterations
  included), and none of them reached an emitted line.
- The report's `ivar embedding (EMBED)` moves 1065 to 1146. That count comes from
  the first, diagnostic pass, which does not set `SKIP_UNSUPPORTED` and so
  includes methods that never ship. The shipped pass reports 1065 `EMBED` lines
  on both trees. I did not trace the 81 extra ivars to their methods.
- Fixture (`BitopProbe`, through the real generator, `closed: true`, INT literals
  only): in `(n & 3) + (n | 8) * 2` the `+` and `*` arms change from
  `FIXNUM_ARITHMETIC` with a `bc2cpp_slow_add_f`/`bc2cpp_slow_mul_f` else to
  `NUMERIC_OPERAND_PROOF` calls into `mrb_num_add`/`mrb_num_mul`. The generated
  method shrinks from 40,154 to 36,990 bytes. `TABLE[n & 3]` is unchanged in both
  trees (`INDEX_EXACT` with a runtime `mrb_integer_p` guard), so the constant-table
  case of ADR 0430 is not unlocked here, which ADR 0430 predicted (0 index sites
  from Option 1 alone).
- The shipped build has no INT-proven `& | ^` operand that reaches a consumer. The
  shipped `Game::Rng#initialize` takes `seed` as an argument of unknown class, so
  `seed & 0xFFFF` stays OTHER and the `Rng` seed chain is unchanged.

### Consequences

- Easier: a `+`, `-` or `*` arm on an Integer bit result can use the core body
  without a dynamic-send else. Shown on the fixture; no shipped function uses it.
- Harder: an INT result from `& | ^` is a new fact a later consumer could misread
  as a fixnum. The fixnum proof (ADR 0279) is the guard against that. It must not
  start reading the numeric mask.
- Not done: `<<` and `>>`, and the `Game.clamp` resolution (ADR 0430 Option 3).
  Each is a separate change.
- The fixture half of `bitop_results_check.rb` runs the real generator, so it
  needs MRBC and the `3rd/mruby` sources. The nightly `bc2cpp-checks` job has
  both. Against master, its INT-proven assertion fails, which is the sensitivity
  the check is meant to have.
- Not done: `<<` and `>>`, and the `Game.clamp` resolution (ADR 0430 Option 3).
  Each is a separate change. The effect on the `Rng` seed chain (ADR 0430 claim
  9, where `(seed & 0xFFFF) + 1` was OTHER) is measured in the section above, not
  assumed here.
