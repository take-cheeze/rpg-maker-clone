# ADR 0175: bc2cpp typed `empty?` calls before container intrinsic

Date: 2026-09-21

## Status

Accepted

## Context

bc2cpp emitted its `Array`/`Hash`/`String` `empty?` intrinsic before trying
the existing exact receiver-class analysis. As a result, a compiled call on a
fresh `Game::MoveRoute` always went through the intrinsic's default
`mrb_funcall` arm even though `Game::MoveRoute#empty?` was a compiled Ruby
method and the receiver was constructed at that call site.

## Decision

Defer the built-in `empty?` lowering until exact receiver devirtualization has
had a chance to select a compiled Ruby implementation. If the existing guarded
typed path cannot prove a compiled target, retain the current exact-container
intrinsic and its dynamic fallback unchanged.

## Consequences

Known Ruby implementations can use the same runtime class guard, direct
compiled call, and `mrb_funcall` fallback as other typed sends. Calls without a
usable target continue to use the built-in container checks or ordinary Ruby
dispatch. The change only reorders a safe optimization opportunity; it does
not assume that a receiver is a built-in container or that its method cannot
be overridden.
