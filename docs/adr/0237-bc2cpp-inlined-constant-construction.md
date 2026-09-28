# 0237. Resolve constructors through inlined constant lookups

Date: 2026-09-28

## Status

Accepted

## Context

Some compiled `:new` calls occur inside an inlined block or expression. Their
local call emitter has no instruction index, even though the bytecode IR keeps
the source instruction and receiver register. Constructor analysis previously
required the local index, so these constant receivers stayed dynamic. Several
native RGSS classes were also reachable through `Object.include RGSS` without
a canonical path from native-source scanning.

## Decision

Use the source index and register mapping already carried for receiver proofs
when tracing `:new` through inlined code. For RGSS native constructors, require
the closed-world standard constructor chain and guard the generated call with
the gem-init-captured native class pointer. Resolve core `String` and `NameError`
constants only when the standard constructor chain is proven and the runtime
class pointer matches mruby's built-in class. Factor RGSS `Table#initialize`
state setup so both its ordinary wrapper and direct constructor share it.

## Consequences

Constant-based constructor sites in inlined code can use direct native or
generic construction while other classes and argument shapes keep ordinary
Ruby dispatch. The source-index proof uses bytecode facts; the runtime identity
guard handles a receiver whose value differs from the traced constant.
