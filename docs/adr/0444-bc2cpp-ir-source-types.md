# 0444. Read-point receiver source proofs in IR feedback

Date: 2026-10-14

## Status

Accepted

## Context

IR feedback lacks existing independent proofs for ivars, constants and incoming
arguments. Global ivar types alone cannot describe initialization or intervening
calls. Signature bounds must remain distinct from independently proven classes.

## Decision

After shared reaching definitions succeed, queries with an ivar, constant or
incoming argument source may consume the settled exact-class state at that
register read. Reuse the call-result mask decoder and its closed-world,
singleton-free and settled-analysis gates. Reject unknown, guarded, exception,
empty and unmodelled masks. Preserve all shared control-flow and clobber refusals.

Use read-point states instead of producer or global masks: they include ivar
nil initialization, local stores, call invalidation, joins and argument pools.
A complete independent proof takes precedence over a nominal RBS contract;
otherwise the existing inference and declaration fallback remain available.
`BC2CPP_IR_SOURCE_TYPES=0` disables only the reporting bridge.

## Consequences

IR feedback and independent RBS suggestions can reuse audited receiver-source
facts without a second mutation or call-site model. More contract mismatches
may become visible. Element types, opaque callers and guarded handler paths
remain unknown. This bridge changes reporting, not generated dispatch.
