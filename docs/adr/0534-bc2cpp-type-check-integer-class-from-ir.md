# 0534. bc2cpp: the type check's integer-class rows come from the bytecode IR

Date: 2026-10-21

## Status

Accepted

## Context

ADR 0501 stage 2 moved the Fixnum-admitted names, the folded values and the intervals to `BytecodeIR::ConstantFacts`.
ADR 0533 found one producer still on the old walk: the bignum-capable class proof (CLASS_INTEGER_PROOF). Its input
`integer_class_constants` is report-only; codegen never reads it, and only `type_facts.rb` (the type check) does.
`IntegerConstants.class_admitted` builds it.

The old class proof refuses literal-only arithmetic whose exact value falls outside the Fixnum margin, and every name
built on that arithmetic. The IR keeps the class of such a name separately from its value, so it can say `Integer` for
these names too.

## Decision

- `BytecodeIR::ConstantFacts::Result#integer_class_names` is the set of names whose every binding is an Integer, of any
  size (an out-of-margin literal has class Integer and no value).
- `bc2cpp.rb` passes that set as `integer_class_constants` when the closed world shows every constant binding static.
  `IntegerConstants.class_admitted` is no longer on the build path. It stays as the oracle that the constant typing
  check compares against.
- A name with a division by an exact zero in any binding is left out of `integer_class_names` (`Result#zero_divisors`).
  A zero divisor raises before the name holds a value, and the old proof refused it; `constant_typing_check.rb`
  (`ZF_ZERO`) pins that. The value, Fixnum and interval sets do not change.

## Verification

- `scripts/bc2cpp/const_bitor_io_check.rb`: all checks pass. New checks: the IR class set contains the old one on the
  positive program, and on a literal-only bignum program the IR keeps exactly `CB_ADD`, `CB_SUB`, `CB_CHAIN` and
  `CB_LOOK`, which the old proof refuses. `CB_ADD` is typed `Integer` end to end.
- `scripts/bc2cpp/constant_typing_check.rb`: new checks compare the IR intervals with the interval proof (equal on the
  positive program), and the IR Fixnum set with the exact-value proof. The only exact-value name outside the IR Fixnum
  set is `ZA_BIG`, which lies outside the margin; every IR-only Fixnum name has an interval. The script still fails 3
  checks on the base commit in this environment (frozen Array sums); those checks are unchanged here.
- `type_check.rb --files` on a fixture program with bignum literal arithmetic: five rows change from untyped to
  `Integer` (`inferred:integer-class`), all of them literal-only bignum arithmetic or a name built on it. A fixture
  with no such arithmetic gives identical rows.
- The 67 coverage checks (`scripts/coverage/report.rb` CHECKS) on the base commit and on this change, both with the host
  `mrbc`: 51 pass in each, with no per-check status change. Sixteen checks fail in both trees in this environment.

Not run: the closed-world type check on the engine, so the engine-level row diff is unmeasured. The generated C++ was
not compared, because codegen does not read `integer_class_constants`.

## Consequences

- The type check no longer uses `IntegerConstants.class_admitted` on the build path. The old analyzer remains the
  oracle, and the retirement of `IntegerConstants` is still open (ADR 0533).
- Rows for bignum-literal arithmetic become `Integer` where they were untyped. This is more precise and sound under
  the operator gate (an Integer operator on Integer operands is an Integer). Rows built on a literal bignum that another
  producer already types keep their earlier type, because the class producer runs after the earlier ones.
- Still open: the RBS-declared integer names (`DeclaredConstants.check`, ADR 0533) and the container rows. Retiring
  them needs a closed-world measurement with the signature set.
