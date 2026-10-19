# 0511. Share compatible constant-typing fixtures in one check suite

Date: 2026-10-20

## Status

Accepted

## Context

The frozen-container and integer-arithmetic checks each launch the type-check
CLI for small constant programs. Their safe positive fixtures can coexist,
and both test the same Object#freeze replacement. Separate scripts duplicate
the CLI harness and run 16 whole-program analyses between them. The arithmetic
harness also accepts a nonzero exit if JSON exists, because default engine
signatures do not belong to its fixture programs.

## Decision

Combine both checks in `scripts/bc2cpp/constant_typing_check.rb`. Share one
positive program and one Object#freeze replacement program, reducing CLI
analyses to 13. Keep every original assertion, including the independent
in-process integer-interval and operator-gate checks. Keep other method
replacements, prepends, unknown mixins and receiver refusals in separate
closed worlds. The common CLI harness supplies an empty signature directory
and requires success before reading the constant rows.

## Consequences

CI and local runs use one suite with the same named assertions and fewer
compiler analyses. A future fixture may join a shared program only if its
method definitions and constant names preserve the other cases' assumptions;
otherwise it needs its own program. The suite still tests the public CLI and
its JSON report rather than bypassing them with private compiler calls.
