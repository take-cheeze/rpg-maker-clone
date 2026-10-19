# 0512. Share an IR block check process while isolating fixture worlds

Date: 2026-10-20

## Status

Accepted

## Context

Capture, yield, RBS callback and reaching-operand checks load overlapping bc2cpp
libraries in four Ruby processes. The coverage reporter registered all four,
but the MRBC-enabled CI job only ran the operand check, leaving the real capture
and yield fixture branches unexecuted there.

## Decision

Run these related IR block facts through `scripts/bc2cpp/ir_blocks_check.rb`.
Load each case file into its own anonymous module and share temporary-source
compilation through `Bc2cppIrBlockFixtures`. Preserve each fixture's separate
program and analysis, including distinct operand worlds. Register the suite
once in coverage and once in the MRBC-enabled build job. Keep host capture and
callback assertions available when MRBC is absent, and report fixture skips.

## Consequences

Libraries load once, helper names cannot collide, and CI exercises all existing
fixture assertions. Case files are suite internals rather than standalone
checks. Full-runtime block tests remain separate because their compiled-code
and full-core library requirements differ from these IR facts.
