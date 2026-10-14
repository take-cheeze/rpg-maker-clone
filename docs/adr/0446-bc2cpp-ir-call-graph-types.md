# 0446. Complete argument facts across reporting call graphs

Date: 2026-10-14

## Status

Accepted

## Context

Existing compiler class pools already propagate through unique-name call graphs.
Reporting can also prove receiver-specific arguments for polymorphic names, but
those facts are absent from canonical states used by downstream forwarding calls.
Feeding them into optimizer pools would change dispatch assumptions.

## Decision

Build a separate reporting summary table over required-argument method bodies.
Seed only complete independent receiver-specific caller joins. In bounded rounds,
query caller registers with shared IR types seeded from the previous complete
argument summaries, plus existing independent source and call-result proofs.
Reuse exhaustive caller admission and stable actual target lookup for every join.
Implicit sends still read self, never old output-register values.

Publish a summary only when every relevant caller contributes a complete may-set
and every unrelated caller can be excluded by complete receiver/target proof.
Never publish partial joins or treat unresolved recursion as an empty type. Refuse
shared/aliased body identities, unknown callers and unsupported arities. Bound the
analysis to 8,192 parameter nodes and 16 rounds; retain only completed facts at a
round limit. Cache the settled table separately from all optimizer proof tables.

## Consequences

Forwarded unions can type parameters and IR returns through multiple receiver-
specific graph edges. Existing closed-world, reflection, singleton, clobber and
handler restrictions remain intact. Unresolved recursive components need a later
inductive/SCC analysis and remain unknown here. RBS declarations are not graph
seeds. `BC2CPP_IR_CALL_GRAPH_TYPES=0` disables this reporting extension.
