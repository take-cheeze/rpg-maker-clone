# 0238. Resolve construction through singleton-method self

Date: 2026-09-28

## Status

Accepted

## Context

Bare `new` inside a class method receives the class object as implicit `self`.
bc2cpp treated every implicit-self send as lacking a receiver class proof, so
even `Game::State.load` and `Game::Picture.from_h` kept dynamic constructor
dispatch despite their singleton-method owners naming those classes.

## Decision

For implicit `new`, derive the class object only from an emitted class's
`.singleton` method owner. Feed that class proof through the existing
constructor paths, which still require a standard constructor lookup chain and
the appropriate native or compiled initializer checks.

## Consequences

Bare constructors in stable class methods can use the same direct construction
as explicit constant receivers. See ADR 0239 for receivers that select from a
finite set of classes at runtime.
