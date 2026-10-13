# 0437. Optimize bytecode IR without workload-specific rules

Date: 2026-10-13

## Status

Accepted

## Context

The Optcarrot probe accumulated source rewrites, hardcoded CPU method lists,
an exact tile-initializer IREP matcher, and class-specific array fast paths.
These measured useful opportunities but made performance depend on benchmark
identity rather than general compiler facts.

## Decision

Remove workload-specific transformations and compiler eligibility conditions.
Retain general method/resumable IR inlining and benchmark compatibility/host
infrastructure. Prefer finite value sets, escape analysis, effects, integer
intervals and continuation proofs for future specialization. The replacement
plan is in ../bc2cpp-generic-ir-optimization.md.

## Consequences

The benchmark exercises upstream Ruby and exposes remaining compiler costs.
Historical optimized timings no longer describe this configuration. Recovering
those gains requires generic computed-send/splat optimizations and initializer
compilation; removing specialization alone cannot retain prior performance.
Architectural history and its old measurements remain available in earlier ADRs.
