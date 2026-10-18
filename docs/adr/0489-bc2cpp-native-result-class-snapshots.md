# 0489. Reuse native-result receiver-class snapshots

Date: 2026-10-19

## Status

Accepted

## Context

The non-hot whole-engine profile identified `native_result_flow_mask` as an
allocation hotspot. Every query converted the numeric class-bit hash to an
array, rebuilt the four core-class pairs, and tested the receiver against
every class bit with `Integer#anybits?`. A class result can discover another
class bit during the query, so iterating the mutable hash directly would
change behavior or raise while adding an entry.

Probe rollback (`without_probe_side_effects`) shallow-copies container ivars
and later restores them. Class-table size alone cannot identify which table
a cached snapshot describes.

## Decision

Keep a frozen snapshot of receiver class/bit/position entries per generator.
Reuse it only while the numeric class-bit hash has the same identity and size.
Production writes to that hash only append through `numeric_class_bit`;
changing or deleting an existing entry would require new invalidation.

The four core-class entries are frozen once. A query keeps its local snapshot
even if a callback discovers a class and replaces the generator's memo. The
next query sees the new class. Probe rollback restores the memo alongside the
other state; the identity check also refuses a memo pointing at a different
hash than the restored class table.

Each entry represents exactly one bit: numeric classes use `1 << index`, and
the four core masks are powers of two. Test that position with
`recv[position] == 1`, with the position derived once per snapshot entry,
instead of constructing a bignum intersection.
Ruby's signed bit indexing preserves the old test for negative receivers too.
Lookup order, result joins, remaining unknown bits and nil handling stay the
same. No oracle answer is cached.

## Consequences

Receiver queries stop allocating a fresh array and entry for every known class
and avoid the temporary intersections for membership tests. Snapshot rebuilds
still allocate when the table grows or is replaced. Retaining the old
snapshot during a query preserves class discovery and reentrant lookup.

The native-result check compares 4,000 narrow/wide, positive/negative queries
against the previous algorithm, including lookup order and class allocation.
It also checks reuse, immutable entries, equal-size replacement, probe
rollback and class discovery during an active query. Measurements use Ruby 4
with YJIT and hot-only filtering disabled; see
[native-result proof performance](../bc2cpp-native-result-performance.md).
