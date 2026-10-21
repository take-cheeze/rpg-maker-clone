# 0530. Borrow cached reaching definitions for read-only consumers

Date: 2026-10-21

## Status

Accepted

## Context

Reaching-definition results already have immutable cache snapshots, but every
query copies the array, Definition records and register strings. Internal type,
numeric and constant readers inspect these records without changing them.

## Decision

Add an explicit `shared: true` query option for audited read-only consumers.
Cacheable answers may return the existing frozen snapshot. All callers requesting
sharing must treat every returned result as read-only. Keep the public default:
fresh mutable records and strings, isolated from cache state and other callers.

Keep diagnostic and mutable-opaque queries on the original uncached path. Cache
saturation still computes a fresh result without retaining it. These paths do not
promise frozen objects; their answers, refusal causes and budgets are unchanged.
Never freeze caller-owned input strings or mutable diagnostic/opaque objects.

Convert internal type, numeric, constant and writer-index readers whose returned
values do not expose Definition records. Producer and callback APIs that expose
records retain default copying. `BC2CPP_IR_SHARED_DEFINITIONS=0` restores copies
for shared requests, allowing complete report and allocation comparisons.

## Consequences

Repeated read-only cache hits avoid result arrays, records and register copies.
Snapshot lifetime and cache bounds remain those of the bytecode Program. Tests
cover public mutation isolation, deep cache immutability, mutable opaque inputs,
diagnostic refusal preservation, optout and cache saturation.
