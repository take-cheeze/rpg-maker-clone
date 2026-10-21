# 0534. Cache finalized outside-source opacity touches

Date: 2026-10-22

## Status

Accepted

## Context

Full-engine profiling attributes 3.35% of allocation samples to ClosedWorld
opacity queries. Repeated queries split the same qualified owner path, build
temporary arrays and scan the same outside-source touches.

## Decision

After ClosedWorld construction completes its source scans and hierarchy setup,
cache the outside-source touch predicate by declared owner on that world only.
Retain the declaration, synthetic-owner, boot-class, rebinding and dynamic
subclass guards on every query. Cache both positive and negative touch answers;
do not cache the complete opacity result or source-inclusive native queries.

The touch collection is an internal construction result. A new source universe
requires a new ClosedWorld; caches are not shared across worlds. Cache keys are
limited to declared owners that pass the live guards. Constructor-time questions
use the original scan, before the cache exists. BC2CPP_CLOSED_OPACITY_INDEX=0
retains that original path for differential validation.

## Consequences

Repeated owner queries avoid splitting, temporary collections and touch scans.
Changes observed by the live refusal guards remain visible even after warming
the touch cache. Existing host checks cover positive/negative answers, wildcard
touches, source-only touches, owner-path isolation, caller string mutation and
live guards. The existing pipeline comparison also toggles this index to check
complete type facts and receiver rows without adding compiler invocations.

A same-tree full-engine comparison with warmed scan caches allocated 99,714,305
objects with the index disabled and 96,514,755 enabled, approximately 3.2% fewer.
Facts JSON, receiver TSV and diagnostic report JSON were byte-identical across
both initial and repeated runs. The warmed profiled pair took 54.85s and 53.42s;
this single local timing pair is not a CI speed guarantee. Measurements used
Ruby 4.0.5 with YJIT and StackProf object sampling at one allocation in 4096.
