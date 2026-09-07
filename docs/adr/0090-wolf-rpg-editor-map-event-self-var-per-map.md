# 90. WOLF RPG Editor: per-map map-event self-variable keying

Date: 2026-09-07

## Status

Accepted

## Context

ADR 0089 (per-map `event_position` keying) explicitly left `VarStore`'s
own `@map_event_self` banks (a map event's own self-variables, the
"1000000 + 10*Y + X" addressing range) with the identical `event_id`-
alone collision -- two different maps' own event id spaces both start
from small numbers like 0/1/2 -- noting only that `VarStore` had no
`current_map_id` concept of its own to key by yet.

Wiring that up turned out to be the same small shape as ADR 0089 itself:
`map_event_self_bank`'s own callers already resolve entirely inside
`VarStore` (`#number`/`#set_number`'s own `:map_event_self` decode
branches), so the only piece missing was a `current_map_id` `VarStore`
could read at that point, kept in sync with `Wolf::Interpreter#
current_map_id` (added for `SaveLoad`(220)'s own Save case, ADR 0087)
without asking every caller of `current_map_id=` to also remember a
second assignment.

`@common_event_self` (a Common Event's own self-variables) does *not*
share this gap: Common Events are defined once for the whole project, not
per map, so their own ids are already globally unique -- no fix needed
there.

## Decision

- `Wolf::Interpreter#current_map_id=` is now a real setter (not a bare
  `attr_accessor`) that also assigns `var_store.current_map_id`, so every
  existing call site (`WolfRPG#load_scene`, unchanged) keeps both in sync
  through the one assignment it already makes.
- `VarStore` gains its own `current_map_id` accessor (`nil` until the
  first real map load, or in a context with no real map load at all, the
  same as `Wolf::Interpreter#current_map_id` itself).
- `VarStore#map_event_self_bank` now keys `@map_event_self` by
  `[current_map_id, event_id]` instead of `event_id` alone -- the exact
  counterpart, for a map event's own self-variable *bank*, to `#event_
  position`'s own identical fix for a map event's runtime *position*.

## Consequences

- Verified by two new CRuby-level tests (a `VarStore`-level test proving
  cross-map isolation and revisit-persistence for `map_event_self_bank`
  directly, and an assertion added to ADR 0089's own `Interpreter#
  event_position` test confirming `current_map_id=` keeps `VarStore` in
  sync), the CRuby harness (133 assertions, 0 failed), `ctest -R
  mruby_test` (crash count held at the pre-existing 19-crash baseline),
  the testbed and interpreter soak checks, and the compiled binary
  against the real sample game.
- This closes the one remaining piece ADR 0089's own Consequences
  flagged as still open; no other reader-level state was found to share
  the same per-map collision risk.
