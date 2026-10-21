# 0527. Reuse unchanged context evaluations within one root graph

Date: 2026-10-21

## Status

Accepted

## Context

Context analysis repeatedly allocates a fresh numeric flow for every node during
its fixed-point sweeps. Leaf snapshots remove repeated independent work across
roots, but contexts with calls still repeat work after their dependencies have
stabilized. Return masks alone cannot identify stability: readonly effect proofs
inspect callee flow states and recursively inspect further callees.

## Decision

Record every context admitted or read through `add`, including existing nodes
and contexts reached during transitive readonly checks. Each evaluation records
the revision observed at that read. Node revisions change when flow states,
call results, literal arrays or the joined return mask change. Dependency maps
use object identity because nodes are mutable and may form recursive graphs.

At its normal solver turn, reuse an evaluation only if every observed revision
and the numeric-class/private-shape generations remain unchanged. Keep the full
node traversal, admissions, mask joins, graph cap and round accounting. Registering
new classes or shapes conservatively invalidates prior work. A failed graph
never publishes a result. Keep dependency records within one root solve and
clear them afterward, so retained completed roots do not retain whole graphs.

The existing bounded cross-root leaf cache remains separate. Set
`BC2CPP_IR_CONTEXT_REEVALUATION=0` for the original reevaluation path. No new
budget or persistent cache is introduced.

## Consequences

Stable dependencies avoid fresh numeric states, call frames and effect traversals.
Evaluation changes require equality comparisons against old state/call/shape
objects, and each active graph retains bounded dependency edges. This may cost
more for tiny graphs or graphs whose inputs change each round. Roots keep their
original admission and termination behavior, including termination based on mask
changes rather than additional rounds for state-only changes.

Host graph checks compare states and results across caps and round budgets,
exercise a state-changing callee with a stable return mask, and confirm dependency
records are released. Compiler fixtures compare complete reports with reuse
both enabled and disabled, including recursion, effects, shapes and budget
refusals.
