# 0518. Separate reusable leaf evaluations from root context graphs

Date: 2026-10-21

## Status

Accepted

## Context

Each type-report root builds a bounded fixed-point context graph. Repeated callees
and repeated rounds evaluate identical small leaf contexts. Reusing complete
solved graphs would change node admission, effect dependencies or round-budget
refusals, so a graph cache cannot substitute for the existing solver.

## Decision

Keep graph admission, zero initial masks, node visitation order and the round
loop in `IrContextResults`. Move reusable leaf snapshots into
`IrContextLeafEvaluations`, owned by one context engine. Replay a snapshot only
when the node reaches its ordinary evaluation turn, never when it is admitted.

Mark every context lookup during evaluation as a dependency, including lookups
of existing nodes and readonly-effect queries. Retain only evaluations with no
such dependency, non-nil states, no graph failure, and unchanged numeric-class
and private-shape generations. Key them by the complete context key, including
root versus callee binding. Generator analysis tables are settled before report
queries; cache entries never cross generator instances or program worlds.

Snapshots copy and freeze states, call masks and literal-shape records. Retain
at most 128 entries, with at most 4096 state cells each, evicting the oldest
entry on insertion. Larger leaves and all dependent or recursive contexts use
the original evaluator. `BC2CPP_IR_LEAF_EVALUATIONS=0` disables reuse for parity
checks and measurement.

## Consequences

Small independent contexts avoid repeated dataflow evaluation while root graph
budgets and conservative refusals retain their existing behavior. Snapshot
retention is bounded, at the cost of copying eligible results and checking their
generations. Fixture checks compare complete reports with reuse disabled,
including one-node and one-round budgets; engine facts and receiver rows are
also compared before publishing the optimization.
