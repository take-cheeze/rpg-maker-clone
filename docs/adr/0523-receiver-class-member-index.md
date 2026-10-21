# 0523. Index receiver class members to avoid wide-mask scans

Date: 2026-10-21

## Status

Accepted

## Context

Full-engine allocation sampling attributed 8.7% of allocations to receiver-union
classification. It scanned every registered class with `anybits?`, which allocates
temporary objects for wide masks, even when a receiver contains only a few bits.
Readonly call checks repeated this scan and class-name lookup reversed the map.

## Decision

Maintain an inverse bit-to-class index per CodeGen, keyed by the source class-table
identity and size. Class allocation only appends; probe rollback restores a copied
table, so both identity and size are required. Lazily rebuild on growth or replacement.

Enumerate the lowest set bit of a positive receiver mask, in class allocation order.
Every bit must exist in the inverse index and the union must contain at most eight
members. Preserve the two-member minimum for receiver-union dispatch and the
one-member minimum for readonly calls. Reject core, unknown and provenance bits.

Cache immutable decoded member arrays and static decoding refusals by receiver
mask, up to 2048 entries per index generation. Clearing on growth prevents a
previously unknown bit from staying refused after registration. A snapshot remains
valid for an active query even if a callee discovers another class; the next query
reads the new generation. Probe rollback cannot retain transient bit names.
`BC2CPP_CLASS_MEMBER_INDEX=0` retains full-table decoding and reverse name lookup.

## Consequences

Small receiver unions avoid work proportional to all registered classes and repeated
wide-mask membership allocations. No inference, call result or graph budget is
memoized. Host checks compare randomized masks with the original full-table scan,
including unknown bits, width, ordering, growth, rollback and the cache bound.
