# 97. WOLF RPG Editor: a map event page's own repeating Custom move route

Date: 2026-09-08

## Status

Accepted

## Context

ADR 0069 shipped `Page#move_type`/`SetMoveRoute`(201), but left one gap
named rather than guessed at: a Custom-move page whose `route_options` bit 0
("動作を繰り返す", repeat -- cross-confirmed there against the
wolfrpg-map-parser crate's own `Options` struct) is set had its initial
route logged and skipped entirely, rather than applied once and silently
dropping the loop the way a numeric-guess implementation risked. Re-scanning
the sample game's own real usage (the same kind of pass that already found
BreakEvent(172) hiding in a shared fallback bucket) confirmed this is real:
3 of the sample game's 3 real Custom-route pages set the repeat bit.

## Decision

- `Wolf::Interpreter#update_event_movement` now treats a repeating Custom
  route the same way it already treats Random/TowardHero's own ambient
  movement: the *first* run happens once, immediately, on page activation
  (`#apply_initial_move_route`, unchanged from ADR 0069's own "snap, no
  gradual animation" semantics), then `#tick_repeating_route` re-runs the
  *entire* route from its start every `#move_pause_frames(page.move_
  frequency)` frames, forever -- the same cadence helper `#tick_ambient_
  move` already uses for Random/TowardHero, not a fresh guess.
- The activation frame itself does not *also* tick the just-primed timer:
  `#update_event_movement` tracks `just_activated` and skips calling
  `#tick_repeating_route` on that one frame, so the freshly-set
  `pos[:move_timer]` is not ticked down a frame early relative to every
  later repeat -- confirmed by a unit test walking two full repeat cycles at
  once (a single symmetric off-by-one would only show up on the *second*
  cycle, not the first).
- A non-repeating Custom route's own behavior is unchanged: it runs exactly
  once on activation and `#tick_repeating_route` returns immediately every
  other frame (`#repeating_route?` false), matching the pre-existing "must
  not re-apply just because `#update_event_movement` is called again" test.

## Consequences

- All 3 real repeating-Custom-route pages in the bundled sample game now
  actually loop their route instead of running it once and stopping;
  `scripts/wolf_interpreter_check.rb`'s own soak run no longer logs "map
  event page's own repeating custom move route" as unimplemented.
- Two new `mruby-wolf/test/wolf_test.rb` unit tests replace the old
  "skips a repeating Custom route" one: a repeat test walking two full
  pause-then-repeat cycles, and a non-repeat regression test confirming a
  plain Custom route still never re-runs.
- Still deliberately out of scope, unaffected by this change: `SetMoveRoute`
  (201)'s own separate repeat flag (a different code path, 0 real
  occurrences in the sample game so far) and the RouteCommand ids (21/29/47/
  60) ADR 0069 already left unimplemented for lack of an independent
  structural source.
