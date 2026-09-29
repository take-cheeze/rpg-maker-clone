# 0248. Ignore instance mixins in class-object constructor lookup proofs

Date: 2026-09-29

## Status

Accepted

## Context

The constructor proof rejected a class whenever its instance ancestor mixins
were unresolved. For example, an `include Enumerable` in `Game::Party` can be
outside the bytecode's module-name set, even though it cannot affect lookup of
`new` or `allocate` on the class object. This kept otherwise proven constructors
such as `Game::Party.new` and `LCF::Array2D.new` dynamic.

## Decision

Do not use an instance class's unresolved include/prepend status to reject its
class-object constructor lookup. Continue rejecting unresolved or known mixins
on the class object's singleton owner, and on `Class`, because those can
intercept `new` or `allocate`. The constructor proof separately verifies the
class hierarchy and registered overrides.

## Consequences

The wio closed-world report removes 12 dynamic `:new` markers: 913 to 901 generic
`POLY` sites, with emitted direct constructor paths increasing from 599 to 611.
The closed-world regression covers a class with an unresolved instance mixin.
