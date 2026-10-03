# 0326. bc2cpp: interval constants vouch for the operands of the Fixnum proof's consumers (NUMERIC_INTERVAL_OPERANDS)

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0318 built a proof that a register is a Fixnum with a known interval (`fixnum_interval`, constants from
`IntegerConstantRanges`, `+ - * /` of those) and asked it only for native `:int` arguments. Its next levers listed
using it for the other Fixnum consumers (`ADD` arms, `times`, index operands) in place of ADR 0279's retired source 4,
and for user readers of constants. The Fixnum proof (`proven_fixnum_operand?`) had two gaps this fills:

* a constant defined by `MUL`/`DIV` (`HEAD_H = LINE_H + BORDER * 2`, `COLS = W / TILE + 1`) is not an
  `IntegerConstants` name, and the result of an `ADD`/`SUB`/`MUL`/`DIV` is never a proven Fixnum (it may leave the
  range), so `HEAD_H * 3 + 1` kept a tag test and a `slow_*` else at every step;
* an Array index never asked the proof at all (`mrb_integer_p` plus a `[]` send for the else), even for a literal.

### Measurement (wio closed world, master `7818f0f5`, `3rd/*` populated, shipped pass)

| | master | default | |
| --- | ---: | ---: | --- |
| `bc2cpp_send` call sites | 2,538 | 2,496 | -42 |
| `bc2cpp_slow_*` callers (`add_f` 720 -> 719, `sub_f` 479 -> 473, `mul_f` 451 -> 441) | 3,343 | 3,326 | -17 |
| `mrb_fixnum_p(` / `mrb_integer_p(` tests | 3,597 / 3,822 | 3,444 / 3,510 | -153 / -312 |
| `operands proven Fixnum` arms / proven Array index sites | 388 / 0 | 556 / 42 | +168 / +42 |
| `bc2cpp_getidx`, `bc2cpp_setidx`, `bc2cpp_nomethod` | 2,066 / 210 / 4,386 | same | 0 |

The cutoff for this change was 30 removed `slow_*`/by-name sites in the engine gems; it removes 59 (42 sends and 17
helper callers) plus 153 numeric guard arms. The intervals alone (before the index change) removed 17 helper callers and
153 tests and no send: the 42 sends are the `[]`/`[]=` elses of Array sites whose index is now proven. The user-reader
lever (`left_panel_w`-style methods returning a constant expression) rides on the same change: `compute_fixnum_return_names`
asks `proven_fixnum_operand?`, so a reader whose return interval is proven becomes a Fixnum-returning method; it is part of
the numbers above (not separable without a second kill switch) and was not measured on its own.

## Decision

`fixnum_proof_source?` gains three sources, gated by `numeric_intervals_on?` (`BC2CPP_NUMERIC_INTERVALS != 0`, a closed
world with a static constant world and native `+ - * /`, i.e. `fixnum_intervals_on?`):

* `GETCONST`/`GETMCNST` of a name with an `IntegerConstantRanges` interval (every definition visible, hull inside the
  narrowest Fixnum range);
* `ADD`/`SUB`/`MUL`/`DIV`/`ADDI`/`SUBI` whose operands have intervals and whose result interval fits
  (`fixnum_interval_source`): the result is a Fixnum, so the next operation needs no test. Overflow of the operation
  itself was never the question: the exact tier (`fixnum_exact_tier`) already promotes an overflowing result.

`GETIDX`/`SETIDX` with an exact Array receiver (INDEX_EXACT, ADR 0296) and an index that `proven_fixnum_operand?` proves
(literal, interval constant, an expression of those, any other source of the proof) call `bc2cpp_ary_entry`/`mrb_ary_set`
with `mrb_integer(idx)` directly: no integer test, no by-name `[]`. A non-exact receiver keeps its tests.

Kill switch `BC2CPP_NUMERIC_INTERVALS=0` (and `BC2CPP_NUMERIC_CONSTANTS=0`, which removes the intervals): the shipped C++
is byte-identical to a clean master build (`cmp`, checked). Soundness is ADR 0318's: the interval of a name is a fact about
every definition the closed world can see, a join, a protected range and `GETUPVAR` give up, and a redefined `Integer#+`,
a `const_set`/`remove_const`/`const_missing` or an open world turn it all off.

## Consequences

* `HEAD + 1`, `HEAD * 3 + COLS - 2`, `a[HEAD - 22]`, `a[1]` lose their tag tests; the numbers are above.
* A sound `slow_*`/`getidx` caller still stays wherever an operand is a parameter, an element, an unproven reader or a
  value above the Fixnum range.
* `Array#size`/`length` times a constant (the 11 `size * LINE_H` sites of ADR 0318) is not provable: the product can
  overflow the narrowest Fixnum.

### Evaluated, not built: a hoisted runtime guard for `size`/`length`/`max` (lever 5)

At most 11 `Bitmap.new` sites (ADR 0318) have this shape. A guard would have to test `mrb_integer_p(size)` and its
product range once before the call and branch to the whole by-name path otherwise, so a user `size` override returning a
non-Fixnum still reaches the same send with the same arguments. That is a second compiled copy of each method (or a
per-site slow path), for at most 11 removed sends, which is under the cutoff by itself and costs generated code size; not
built. The cheaper next levers are the engine rename that restores the inlined `Game::Variables::MAX`/`MIN` (ADR 0324) and
user-reader intervals with their own switch.

## Tests

`scripts/bc2cpp_numeric_intervals_check.rb`: generated code for four arithmetic and three index positives and seven
negatives (a parameter, a constant above 32 bits, a Float constant, an arithmetic result of an unproven operand, a
parameter receiver, an index parameter, a Float index constant), five withdrawal worlds (a reopened String constant, a native
definition, `const_set`, a redefined `Integer#+`, `const_missing`), the open world and both kill switches; the fixture on
real mruby interpreted and compiled (values and exceptions, with a Hash and a String reaching the parameter receiver),
full-core, core-only and 32-bit `mrb_int`, with zero dispatches on the proven methods.
`scripts/bc2cpp_numeric_intervals_mutation_check.rb`: an unmutated control and nine mutants (each kill switch ignored,
every index or constant proven, no static-world gate on either source, an arithmetic result always a Fixnum, the Array read and
write not using the proof), each killed. New `numeric-intervals` shard in `bc2cpp-checks`; the 32-bit run is in
`bc2cpp-width (int32)`.
