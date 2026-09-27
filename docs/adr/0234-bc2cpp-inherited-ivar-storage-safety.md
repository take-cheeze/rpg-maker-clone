# 0234. Keep embedded ivars off bases with initializing subclasses

Date: 2026-09-27

## Status

Accepted

## Context

Embedded ivar structs are allocated by the compiled `#initialize` belonging to
the layout owner. A subclass that overrides `#initialize` without calling
`super` can instantiate an object whose inherited method accesses that
owner's embedded fields before any compatible RData payload exists. C++
inheritance between generated structs does not address this: the runtime still
needs to allocate the most-derived payload and preserve matching RData type
metadata.

## Decision

When a base layout is eligible for embedding, each known descendant that
defines `#initialize` must contain a `SUPER` instruction or compilation fails
with a storage error. Embedding is retained only when that `SUPER` is the
initializer's first executable bytecode operation and no included or prepended
module interposes on initialization. A later or conditional `super` remains
legal Ruby but keeps that base layout in mruby's ordinary ivar table. This lets the
compiler reject the unsafe no-`super` case while remaining conservative about
initializers it cannot prove safe.

## Consequences

This enforces the storage contract at compile time without changing mruby's
RData allocation ABI. A first-operation `super` reaches the ancestor
initializer before subclass work can read inherited storage. The proof relies
on the compiler's known superclass graph; separately compiled or otherwise
unregistered subclasses still require a whole-program hierarchy proof.
