# 89. WOLF RPG Editor: per-map event position keying

Date: 2026-09-07

## Status

Accepted

## Context

Both `Teleport`(130) (ADR 0080) and `SaveLoad`(220) (ADR 0087) flagged the
same gap in their own Consequences without fixing it: `Wolf::Interpreter#
event_position`, the runtime `{x:, y:, direction:, page_index:,
move_timer:}` every map event's own current position/state lives in, is
keyed by `event.id` alone in `@event_positions`. Two different maps' own
event id spaces both start from small numbers like 0/1/2, so revisiting a
map after leaving it -- something both of those commands can now genuinely
do -- would read (and silently corrupt) whatever *other* map's same-id
event happened to leave behind, instead of finding this map's own event
exactly where it was left.

Re-checking this after `Party`(270) (ADR 0088) found the fix itself
smaller than the TODO's own "persistent per-map event state" framing
suggested: `event_position` has exactly one call site for
`@event_positions` itself (its own definition), and `Wolf::Interpreter#
current_map_id` (added for `SaveLoad`(220)'s own Save case, ADR 0087)
already gives every caller the map id needed to key it precisely, so this
needed nothing beyond `event_position`'s own body.

`VarStore`'s own per-map-event self-variable banks (`@map_event_self`,
keyed the same "event id alone" way) have the identical collision, but
`VarStore` has no equivalent `current_map_id` concept of its own to key by
yet, and plumbing one through would touch far more of its own decode path
than this one-call-site fix does -- left as still open, not newly
introduced by this pass.

## Decision

- `Wolf::Interpreter#event_position` now keys `@event_positions` by
  `[current_map_id, event.id]` instead of `event.id` alone. `current_map_
  id` is `nil` in a context with no real map load at all (this method's
  own test suite, `scripts/wolf_interpreter_check.rb`'s own map-event pass
  before any Teleport/Load ever runs), where every event on that one
  implicit map still keys uniquely off its own id, unchanged from before.
- Nothing else changes: `Teleport`(130)/`SaveLoad`(220)'s own Load already
  replace `current_map`/`current_map_id` together (their own existing
  code, unmodified here) without ever clearing `@event_positions`, so a
  revisited map's own events now correctly find their own prior state
  instead of either colliding with a different map's or -- the two
  ADRs' own prior wording -- appearing to "not persist" at all.

## Consequences

- Verified by a new CRuby-level test (two `WolfTestMap`s sharing an event
  id, proving both isolation -- moving one map's own event does not affect
  the other's identically-numbered event -- and persistence -- returning
  to the first map's own id finds the earlier move still applied), the
  CRuby harness (132 assertions, 0 failed), `ctest -R mruby_test` (crash
  count held at the pre-existing 19-crash baseline), the testbed and
  interpreter soak checks, and the compiled binary against the real sample
  game.
- `VarStore`'s own `@map_event_self`/`@common_event_self` self-variable
  banks keep the same "event id alone" collision this fix does not touch
  -- still real, still tracked, just not part of this pass.
- Whether this alone unblocks any *more* of `Teleport`(130)'s own real
  `-1`/`-3..-7` target surface was not investigated here: those targets'
  own semantics (an event "relocating itself" across maps, when each
  map's own event list is a fixed, separate definition) raise a different
  question this fix does not answer either way.
