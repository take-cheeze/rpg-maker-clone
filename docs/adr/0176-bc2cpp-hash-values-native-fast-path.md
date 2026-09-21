# ADR 0176: bc2cpp exact Hash#values native fast path

Date: 2026-09-21

## Status

Accepted

## Context

The map picture movement check calls `@pictures.values` while examining
`Game::Picture` objects. Its backing field is a Hash, but the generated
program used dynamic Ruby dispatch for `Hash#values`. mruby exposes the
method's implementation as the public `mrb_hash_values` API. That API assumes
an RHash receiver, so calling it without checking the runtime object would be
unsafe and would bypass subclass overrides.

## Decision

For a name proven to have only the native `values` definition, lower calls
through `mrb_hash_values` only when the receiver is an exact base Hash. Check
both the Hash type tag and `M->hash_class`; all other receivers retain ordinary
`mrb_funcall` behavior. The whole-program report counts these guarded call
sites explicitly.

## Consequences

Exact Hash calls avoid method lookup while preserving subclass overrides and
the normal Ruby error behavior for non-Hash receivers. The operation still
allocates and fills the returned Array, matching mruby's native implementation;
this decision removes dispatch overhead only.
