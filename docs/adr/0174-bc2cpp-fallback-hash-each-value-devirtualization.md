# ADR 0174: bc2cpp fallback Hash#each_value value devirtualization

Date: 2026-09-21

## Status

Accepted

## Context

Blocks passed to methods bc2cpp cannot inline are emitted as standalone cfuncs.
Those fallback blocks previously lost the Hash value type, so calls inside
`Hash#each_value` used dynamic dispatch even when the closed-world Hash
analysis had proven the stored value class. `Game::State#update_pictures` runs
this path every frame for `Game::Picture` values.

## Decision

For an explicit one-argument block passed to `Hash#each_value` with no explicit
method arguments, pass the proven Hash value class into the fallback block's
existing guarded element-send lowering. The exact class is checked at runtime;
unmatched values retain `mrb_funcall` fallback behavior. Unknown or
heterogeneous Hash values remain dynamic.

Use an explicit block in `Game::State#update_pictures` so the value type can
flow into the fallback block and `Game::Picture#update` can use guarded direct
dispatch.

## Consequences

Known Hash value calls in fallback blocks can use compiled Ruby implementations
without assuming every runtime value has the inferred class. The guard and
dynamic fallback preserve behavior for subclasses or unexpected values.
Symbol-to-proc forms such as `each_value(&:update)` do not expose a block body
to this analysis and remain unchanged unless handled by a separate lowering.
