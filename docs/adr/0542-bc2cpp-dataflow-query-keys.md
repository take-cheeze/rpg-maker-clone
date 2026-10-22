# 0542. Reuse immutable reaching-definition query key preparation

Date: 2026-10-22

## Status

Accepted

## Context

Embedding probes repeatedly ask IR reaching-definition questions while compiling
nested callees. Cache hits still copied and froze the query register and every
opaque register name, then sorted a fresh opaque-register key.

## Decision

Use the caller register string for lookup, and copy/freeze it only before storing
a new query key. The transient lookup key is never retained on a hit.

Memoize opaque-register snapshots by container identity only for ordinary frozen
Sets containing frozen Strings. Freezing a container alone does not freeze its
members: other containers and Sets with mutable members rebuild the existing
sorted snapshot on every query. Mutable containers and refusal diagnostics keep
the uncached path. The identity memo shares the query cache's 1024-entry bound;
saturation recomputes snapshots without evicting old entries.

Preserve every query option, result ordering, fresh/public result ownership and
shared/read-only result semantics. `BC2CPP_IR_QUERY_KEYS=0` restores the original
key preparation for differential checks.

## Consequences

Repeated structural proof queries allocate less without changing method-probe
order or sharing eligibility across layouts. Cache entries retain their own
register strings; caller mutation cannot corrupt them. The extra bounded memo
retains immutable opaque Sets for the lifetime of their IR Program.

A warmed Ruby 4.0.5/YJIT full-engine comparison on base `4ccd606d` reduced
allocations from 88,005,453 to 86,413,003 (1,592,450 fewer, 1.81%). Complete
facts JSON, receiver TSV and report JSON were byte-identical. One object-profiled
timing pair was 51.172s versus 50.805s; this does not establish a stable wall-time
speedup.
