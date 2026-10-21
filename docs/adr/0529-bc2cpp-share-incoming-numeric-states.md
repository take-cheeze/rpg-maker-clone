# 0529. Share read-only incoming numeric states

Date: 2026-10-21

## Status

Accepted

## Context

NumericFlow copies an edge state when it first reaches an instruction. A transfer
has already copied that state before writing it, and every later join copies on
growth. The first-edge copy retains no additional isolation within the solver
and adds a full state array for every reached instruction.

## Decision

Treat flow-owned incoming arrays as read-only and share the first incoming
state. Transfers, truthiness and class refinements, handler widening and joins
retain their existing copy-before-write behavior. This invariant covers the
complete state layout: registers, ivar slots, elements, provenance and class
tests. Consumers of NumericFlow results read these arrays without mutation;
a writable consumer must copy first. Existing numeric, return, block and context
consumers only read their states, and reusable context leaf snapshots already
copy and freeze their entries.

The standalone join_state helper keeps its default first-edge copy contract.
Only the solver explicitly requests sharing. BC2CPP_NUMERIC_SHARE_STATES=0
restores the old solver copies for whole-report comparisons.

## Consequences

Reached instructions allocate fewer full state arrays. Oracle order, writes
collection, worklist admission and all widening and narrowing rules stay the
same. No oracle result or partial inference is cached. The speed check freezes
intermediate states at transfer, handler, refinement and join boundaries, then
compares shared and copied runs through branches, loops, captured registers,
slots, class tests, element masks and context-specific ENTER edges.

Future consumers and solver changes must preserve the read-only invariant. The
arrays are not frozen in production, avoiding freeze overhead; tests enforce
copy-before-write at solver boundaries.
