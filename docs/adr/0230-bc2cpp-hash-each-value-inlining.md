# 0230: Inline proven Hash#each_value blocks

Date: 2026-09-24

## Status

Accepted

## Context

The flash-limited bc2cpp builds still emit a standalone cfunc-backed RProc for
several block-carrying sends that have a provable container receiver. The current
hot-only RPG2K output had two such `Hash#each_value` sites: `Game::State#update_pictures`
and `RPG2k::Scene::Map#update_vehicle_flashes`. Each site built a block Proc, called
`each_value` dynamically, and included the block-break exception path. The
compiler already had the container trace, value hints, and snapshot semantics
needed to remove that path.

## Decision

Add `HASH_EACH_VALUE_SUPPORT` to the inline-loop passes. A site is admitted only
when its receiver traces to Hash and the block has one mandatory argument with a
clean body. The emitter checks the exact base Hash at runtime, snapshots
`mrb_hash_values` once, and iterates that Array with the same block translation
used by the other inline loops. A proven receiver that is no longer an exact Hash
trips the inliner's guard and raises rather than silently calling an override.
Unknown receivers and bodies that need the existing cfunc/RProc machinery keep
the ordinary fallback.

## Consequences

The real hot-only RPG2K generated source drops from 2,457,756 to 2,456,393 bytes
(1,363 bytes), with both hot `each_value` fallback regions removed. LCF and RGSS
generated sources are unchanged. `scripts/bc2cpp_hash_each_value_check.rb` covers
the values snapshot, result value, `break` result, foreign receiver fallback,
and execution against real mruby. The guard remains a deliberate tripwire: a
future receiver-proof bug fails loudly instead of bypassing a Hash subclass's
method.
