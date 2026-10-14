# 0443. Shared call-result proofs and nominal receiver contracts

Date: 2026-10-14

## Status

Accepted

## Context

The feedback baseline has 4,441 IR queries stopped at unknown call results.
The compiler already has audited result-class proofs, but the IR query layer
cannot use them. Duplicating method lookup would risk disagreement about
native identity, replacements, singleton methods and guarded class pools.
RBS contracts provide a separate nominal route when receiver bounds are known.

## Decision

Expose complete class sets from the settled exact-class return oracle through
`CodeGen#bytecode_ir_call_result_classes`. Require its existing closed-world,
foreign-method and singleton-free conditions; reject guarded, unknown,
exception and unmodelled-kind masks. Reuse the audited primitive builtin rules
for ordinary calls and the block oracle for block calls. Supply these facts to
IR queries as immutable inferred call definitions.

Resolve ordinary explicit-receiver RBS return contracts through receiver facts
and ancestor lookup. Union all receiver results and require every member to
resolve. Carry argument, ivar and callee contract provenance through chains.
Do not use normal return contracts for block calls, including implicit ones,
because a nonlocal break can replace their result.

Bound recursive queries and memoization. Refuse cycles and excessive depth,
expansion or union size; avoid caching context-dependent refusals. Retain all
shared reaching-definition refusals. Present complete contract-assisted return
bounds with source `derived:contracts`, separate from independent inference
and independently inferred RBS suggestions. Add a reporting comparison switch.

## Consequences

IR consumers gain existing call proofs without an alternative lookup model,
and reports can explain contract-assisted call chains. Tests cover mixed
receiver unions, missing summaries, cycles, cache refusal recovery, overridden
builtins, singleton methods, breaking blocks and code-output neutrality.
Declaration coverage may improve less than IR query coverage because the
older report already consumed many compiler return proofs. No runtime speedup
or additional direct-call lowering is claimed by this bridge. General recursive
summary inference and richer receiver/argument refinements remain future work.
