# 0169: Type the party's database argument for bc2cpp

Date: 2026-09-21

## Status

Accepted

## Context

`Game::Party#initialize` stores its first argument in `@db` without a
`bc2cpp` class annotation. The new-game path and both save-restore paths pass
the same `LCF::Database` instance, but bc2cpp therefore left calls through
`@db` without a receiver-class hint. Related database-holding classes already
record this fact in their annotations.

## Decision

Annotate the mandatory `db` argument as `LCF::Database`. bc2cpp uses the
argument fact to infer the class of `@db`; calls to compiled methods on that
receiver can then use the existing exact-class guard and Ruby dispatch
fallback. Add a synthetic regression check for class-argument annotation
flowing through an ivar into a guarded TYPED call.

## Consequences

Calls through `Game::Party#@db` can devirtualize when the target method is
compiled. Runtime class mismatches still use ordinary Ruby dispatch. The
annotation relies on the game's three known construction paths and should be
revisited if a new path supplies another database-like object.
