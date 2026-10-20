# 0522. Index settled method lookup to reduce allocations

Date: 2026-10-21

## Status

Accepted

## Context

A full-engine typing profile attributed 18.8% of allocation samples to method
resolution. Each query reconstructed ordered ancestor paths, repeatedly split
qualified names, and built a Ruby owner Set. These structural inputs are settled
for a `CallFacts::Answers` world, which already memoizes definers and ancestors.

## Decision

Lazily index paths by full class name, simple names by their original name, and
Ruby instance owner sets by method name. Keep all indexes on one Answers instance;
never share them between worlds. Rebuild Answers if hierarchy, mixins, registry or
other world inputs change. Cache nil paths only because unknown hierarchy and
mixin refusals depend on this settled world, not a recursive inference budget.

Preserve prepend/include/superclass order and existing cycle traversal behavior.
Copy path strings before freezing them. Freeze cached path arrays, simple-name
results and owner Sets without freezing caller-owned names. Continue evaluating
native/foreign shadowing and method-missing checks using the existing rules.
Singleton definitions and native placeholders never enter the Ruby owner set.
`BC2CPP_CALL_LOOKUP_INDEX=0` leaves these lookups unindexed for comparison.

## Consequences

Repeated method queries avoid path arrays, traversal Sets, reversed mixin arrays
and qualified-name splits. Index size grows with queried names in one world and
ends with that Answers instance. Host checks cover ordering, shadowing, unknown
paths, cycles, immutable results and world isolation. The existing two-mode
pipeline comparison also disables/enables these indexes without extra runs.
