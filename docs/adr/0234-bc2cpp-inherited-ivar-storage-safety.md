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

`drop_unsafe_embeddings` rejects a base layout when a known descendant defines
its own `#initialize`. Those ivars stay in mruby's ordinary ivar table, so
inherited compiled methods use the runtime ivar API. Descendants that do not
override initialization can continue to use the base layout allocated by the
inherited initializer.

## Consequences

This conservatively gives up embedding for the affected base classes, while
preserving correctness without changing mruby's RData allocation ABI. The
embedded-ivar check covers a subclass initializer that skips `super`. The
proof relies on the compiler's known superclass graph; expanding embedding
across separately compiled or otherwise unregistered subclasses needs a
whole-program hierarchy proof.
