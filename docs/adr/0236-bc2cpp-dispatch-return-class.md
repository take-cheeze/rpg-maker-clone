# 0236. Propagate proven method return classes into receiver tracing

Date: 2026-09-28

## Status

Accepted

## Context

The closed-world generator already computes `class_return_names`: method names
whose every registered bytecode implementation returns an instance of the same
class. That fact was consumed by class-layout inference for implicit self-calls,
but not by ordinary receiver tracing. Consequently a chain such as
`factory.build_widget.draw` could lose the receiver class at `build_widget`,
even when the method's complete return set had been proven.

## Decision

Allow ordinary receiver tracing to consume a class-return fact for explicit
calls. The proof is name-wide and receiver-independent: it exists only when all
registered implementations agree, and the closed-world analysis rejects
foreign definitions and dynamic method installers. Keep the normal runtime
class guard and dynamic fallback at the eventual call site; this fact is a
receiver hint, not a proof that the call's receiver has one exact runtime class.

## Consequences

The full Wio all-method generation remains at 2,520 generic `POLY` calls. It
emits one additional `TYPED` site (623 to 624 in RPG2K); the change does not
remove generic fallbacks at this point. The proof can enable further calls in
chains when a proven method result feeds another receiver trace. A wrong hint
continues through the existing receiver guard and dynamic fallback.
