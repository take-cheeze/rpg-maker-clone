# 0421. Resumable helper IR regions

Date: 2026-10-13

## Status

Accepted

## Context

Optcarrot's synchronous PPU optimization generates Ruby source. The original
PPU instead suspends a Fiber inside clock helpers. Migrating that behavior to
bytecode IR requires preserving every continuation and live register, including
multiple continuations sharing a horizontal clock value.

## Decision

Lower yielding helpers through decoded `BytecodeIR::ResumableRegion` graphs.
Require resolved branches, an explicit return at the end, no rescue/ensure or
nested blocks, and no nonlocal exits or branches into ENTER. Keep the existing
persistent register frame and per-yield resume states. Refuse unsupported
regions before emitting a step function.

## Consequences

Helper lowering now has explicit IR control-flow boundaries and focused refusal
checks. Native yield/resume, return-value and GC-pressure comparisons remain in
the resumable check. The synchronous source generator remains available; this
change neither migrates its clock specialization nor claims a runtime speedup.
A full replacement must prove continuation equivalence rather than using the
horizontal clock alone as a resume discriminator.
