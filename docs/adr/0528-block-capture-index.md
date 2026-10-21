# 0528. Reuse structural block-capture indexes across compilation probes

Date: 2026-10-21

## Status

Accepted

## Context

Embedding validation compiles real method bodies to determine whether they can
use typed storage safely. The existing clean-result cache avoids repeated probes
within a compiler, but probes and later compilation repeatedly recognize block
regions. Their captured-upvar and forwarded-block walks inspect unchanged bytecode
and allocate duplicate arrays. Region admission itself also reads the current
world, frame and layout, so caching complete regions or generated code is unsafe.

## Decision

Give each CodeGen a BlockCaptureIndex over its fixed irep table. Index upvar
captures by body identity. Index forwarded-block levels by body identity, initial
traversal depth and whether native block-given reads are included. Resolve the
registry-sensitive block_given? modeling predicate at each public query, retaining
Ruby overrides. Preserve the original nested traversal and maximum-depth refusal;
cache static unknowns as well as frozen arrays. Upvar pairs are frozen too.

Keep the index in a separate object created before compilation probes. Its
bytecode-only cache survives without_probe_side_effects, while ordinary container
registrations are still copied and restored. The index lives for one CodeGen and
its size is bounded by queried bodies, the existing depth limit and two modeling
modes. Changed bytecode requires a new CodeGen. No inferred state, compile result,
region admission or generated registration is shared through it.

BC2CPP_BLOCK_CAPTURE_INDEX=0 retains the original walkers for full-output and
allocation comparisons. The public array results become immutable; existing
consumers only read them. Mutable region hashes remain fresh for every call.

## Consequences

Repeated probe and final compilation avoid nested bytecode scans and duplicate
capture arrays. The compiler retains the structural snapshots until it is freed.
Tests compare both paths for nested captures, empty captures and depth refusal,
and cover deep immutability, sparse depth queries, modeling changes and rollback.
This reduces structural work; real compile probes and their layout-sensitive
checks remain necessary.
