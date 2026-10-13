# 0436. bc2cpp type check: annotation and signature violations are errors

Date: 2026-10-12

## Status

Accepted. Amends ADR 0412 (TC1004) and ADR 0413 (TC1003/TC1004 on signatures).

## Context

ADR 0412 made a declared type that contradicts the inference (TC1001) an error, and left two annotation
violations as warnings: an annotation token bc2cpp ignores (an unknown class), and an annotation or RBS
signature with more parameters than its method (TC1004). ADR 0413 did the same for a signature naming a method
or ivar class the program lacks (TC1003). A warning costs nothing in the build, so a stale or mis-sized hint stays
in the source until someone reads the report.

## Decision

- TC1003 and TC1004 are `error`, in `tools/bc2cpp/rbs_signatures.rb` (the build aborts on them when a signature
  directory is set, as it already did for other unusable signatures) and in
  `tools/bc2cpp/type_check_report.rb` (`scripts/bc2cpp/type_check.rb` exits 1).
- TC1006 (a `# bc2cpp:` comment wins over a signature) stays a warning: it is a deliberate override, not a
  violation.
- The fewer-tokens case is still fine (a prefix), so it is not reported.

## Consequences

- A type-check run over a program with an ignored annotation token now exits 1. The fixtures in
  `scripts/bc2cpp/type_check_check.rb` and `scripts/bc2cpp/rbs_signatures_check.rb` are updated to match.
- Not measured on the engine yet: whether `type_check.rb` over the wio closed world reports any TC1004 today.
  If it does, each is a stale hint to fix at its source, not a reason to revert this ADR.
