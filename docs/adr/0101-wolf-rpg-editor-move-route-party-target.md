# 101. WOLF RPG Editor: SetMoveRoute/Effect(290)'s own party-member target

Date: 2026-09-08

## Status

Accepted

## Context

`SetMoveRoute`(201)/`SetVariableEx`(124)/Effect(290)'s Character target all
share one target convention (`help/04ev_movesettingB.html`: `>=0` an event
id, `-1` this event, `-2` the hero, `-3..-7` a party member 1-5), resolved
through one shared method, `#resolve_character_pos`. Its own comment (and
`ROUTE_TARGET_SELF`/`ROUTE_TARGET_HERO`'s own header comment) had said
plainly "no party system exists yet" for the `-3..-7` band, sending it to
the same `[nil, nil]`/"unimplemented" path as a dangling event id. ADR 0099
built that party system; ADR 0100 immediately reused the exact same target
convention for the `9180000+` position-addressing range's own `who`
selector. Leaving `#resolve_character_pos` itself unfixed would have meant
two different, inconsistent answers to "does a party-member target
resolve" depending on which command asked.

A real-data census (every `SetMoveRoute`(201)/`SetVariableEx`(124) call in
the sample game checked for a `-3..-7` target) found 0 real calls -- the
same "byte layout confirmed, semantics confirmed by the manual, 0 real
calls" bar ADR 0099's own `Remove`/`Replace`/`RemoveGraphic` and ADR 0100's
own `EVENT_POSITION`/`THIS_EVENT_POSITION` ranges already cleared, for the
same reason: the resolution logic is already fully general (one line, once
`#party_position` exists) and free to add correctly rather than leave two
call sites quietly disagreeing about the same convention.

## Decision

- `#resolve_character_pos` now resolves `-3..-7` (`ROUTE_TARGET_PARTY_MIN`/
  `_MAX`) to `#party_position(-target - 3)` (`-target - 3`, not `#exec_
  party`'s own 1-based "member" arithmetic -- `#party_position` itself is
  0-based, so target `-3` is companion 1/`party_position(0)`, ..., `-7` is
  companion 5/`party_position(4)`). A party member's own `pos` is already
  the live stored Hash the same way a map event's own `#event_position`
  is, so `#resolve_route_target`'s existing "only the hero needs a
  writeback" logic needed no change at all.
- `Effect(290)`'s own Character-target dispatch (`#exec_effect_character`)
  now resolves a party-member target through the same fixed method, but
  still cannot actually flash/shake it: `sprite_key` there only ever names
  `:hero` or a real map event's own id, and `WolfRPG::MapScene#character_
  sprite` (this command's own rendering seam) has no equivalent lookup for
  a party slot. It stays "unimplemented" for a narrower, still-true reason
  than "no party system exists" -- comment updated to say so plainly
  rather than leave the old, now-misleading explanation in place.

## Consequences

- Verified by a new CRuby-level test in `wolf_test.rb` (a real companion
  actually stepping via `SetMoveRoute`(201) target `-3`; an empty slot at
  `-4` still a clean no-op; `Effect(290)`'s own Character dispatch against
  a party target confirmed to still just log, not raise) alongside the
  existing target-convention test (comment corrected: an empty roster's
  `-3` is now a real, member-less slot, not an unsupported band), the
  CRuby harness (169 assertions, 0 failed), `ctest -R mruby_test` (0 KO /
  0 crashes), the testbed and interpreter soak checks, and the compiled
  binary booted against the real sample game.
- **A real off-by-one was caught by the new test, not by inspection**:
  the first draft used `-target - 2`, which resolves target `-3` to
  `party_position(1)` (companion 2) instead of `party_position(0)`
  (companion 1) -- `#party_position`'s own 0-based argument is one less
  than `#exec_party`'s own 1-based "member" numbering that `-target - 2`
  was modeled on without re-deriving it. Fixed to `-target - 3` and
  confirmed by the test actually asserting *which* slot moved, not just
  that a move happened.
- `Effect(290)`'s own party-sprite rendering gap (flash/shake on a
  companion) is a separate, still-open follow-up -- would need a new
  `sprite_key` shape (e.g. `[:party, i]`) and `MapScene#character_sprite`
  support, with 0 real calls of its own to confirm any of it against.
