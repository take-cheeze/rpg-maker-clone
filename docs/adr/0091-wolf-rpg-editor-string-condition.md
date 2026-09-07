# 91. WOLF RPG Editor: StringCondition(112)

Date: 2026-09-07

## Status

Accepted

## Context

`StringCondition`(112), the string-comparison counterpart to the already-
implemented `VariableCondition`(111), was previously left entirely
unimplemented -- every real call unconditionally skipped its own true
branch, treating the condition as always false. Unlike several other
remaining gaps in the real-frequency census (`Teleport`(130)'s own `-1`/
`-3..-7` targets, `Party`(270)'s own roster-shaped remainder,
`BanInput`(126)), this command has full independent structural
cross-validation: the wolfrpg-map-parser crate carries its own dedicated
`StringConditionCommand`/`Operator`/`CompareOperator` structs (unlike
`BanInput`(126), which the crate does not model at all), and it has 33 real
calls across the sample game -- a real, non-trivial well of frequency this
session's own earlier passes had not yet checked.

## Decision

- `arg(0)`'s low nibble is the case count, mirroring `VariableCondition`'s
  own decode exactly; the same nibble's `0x10` else-case bit is not needed
  here either, since `Run#select_branch` already discovers a trailing
  `ElseCase`/`CancelCase` marker directly from the command stream.
- Each of the next `case_count` args is one packed "variable" word: the
  crate's own `Operator` lives in the high byte (bit 0 `value_is_variable`,
  the top nibble the crate's own `CompareOperator` -- `Equals`/`NotEquals`/
  `Includes`/`StartsWith`), the low 3 bytes the self-var/variable address to
  read as a string.
- A literal condition's own comparison text is this command's own string at
  the condition's own index (`cmd.string(i)`) -- confirmed directly by real
  data: a lone condition's own literal sits at string slot 0, and the one
  real 2-condition call's own two literals sit at slots 0 and 1.
- Any args left over after the `case_count` variable words (one 32-bit
  "value" word per `value_is_variable` condition, in order) are consumed by
  their own running counter -- deliberately *not* the crate's own
  `make_conditions`, which shares one loop index across both the value and
  string arrays, correct only when every condition in a command agrees on
  `value_is_variable`. Real data never contradicts that, but this reader
  does not assume it either.
- `Interpreter#evaluate_string_condition` resolves `variable`/the
  `value_is_variable` operand through `var_store.string`, the same
  `Run`-decodes/`Interpreter`-resolves split `#evaluate_condition` already
  uses for `VariableCondition`.

## Consequences

- Verified by 7 new CRuby-level tests (true/else branches, a 2-condition
  case exercising both string slots independently, `Includes`/
  `StartsWith` -- not exercised by any real call but implemented from the
  same enum -- `this common event`'s own self-var string band, and
  `value_is_variable` comparing two string variables), a real-data decode
  check confirming all 33 real calls resolve to a known operator and a
  string-capable address kind with no crash, the CRuby harness (140
  assertions, 0 failed), `ctest -R mruby_test` (crash count held at the
  pre-existing 19-crash baseline), the testbed and interpreter soak checks,
  and the compiled binary against the real sample game.
- `Includes`/`StartsWith` and `value_is_variable` stay unconfirmed against
  real data (33/33 real calls are `Equals`/`NotEquals` with a literal) --
  implemented from the crate's own enum rather than guessed, but worth
  re-checking if a future sample exercises them differently.
