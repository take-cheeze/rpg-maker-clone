# 66. WOLF RPG Editor map events

Date: 2026-09-06

## Status

Accepted

## Context

ADR 0065 gave WOLF RPG Editor projects a running event-command interpreter,
but only for Common Events: the map's own events (`Wolf::Event`/`Wolf::Page`,
already fully decoded by the data layer since ADR 0064 -- id, position,
per-page trigger, up to four appearance conditions, and the same command
list Common Events use) sat on the map, parsed but inert. Without them, a
WOLF RPG Editor project shows geometry and runs its background Common
Events, but every NPC, sign, chest and door is invisible and does nothing --
the next gap `docs/TODO.md` named after the interpreter's initial slice.

## Decision

`Wolf::Interpreter` gains map-event support, reusing its existing
`Run`/`VarStore` machinery rather than a parallel mechanism:

- **Page selection** (`Interpreter#active_page`): the *last* page (in
  editor order) whose every enabled condition holds, or none if no page
  qualifies -- the same last-match-wins convention `mruby-rpg2k`'s own
  `Game::EventPage.select` already uses for RPG2000/2003 map pages, since
  the manual documents only that a page needs *all* its own conditions to
  hold, not the cross-page precedence.
- **A real bug found and fixed while wiring this up**:
  `Wolf::Page::Condition#enabled?` had never been validated against real
  condition bytes. Dumping the sample game's own pages showed every
  *disabled* condition slot carries a real-looking `variable` (1,000,000,
  decoding to map-event self-variable 0 of event 0 -- the "変数呼び出し値"
  widget always stores *some* reference, even unset) with `value` 0, which
  the old `(operator & 0x0f) != 0 || variable != 0 || value != 0` heuristic
  wrongly counted as enabled. The correct signal, confirmed against the
  wolfrpg-map-parser crate's own independent `Condition` struct
  (`operator >> 4` feeds a `CompareOperator` enum whose 0-6 values match
  `Interpreter::OP_GT`.."OP_AND" byte-for-byte, the same cross-check
  `VariableCondition`'s branch structure already relied on), is bit 0 of
  the operator byte alone.
- **Triggers**: Auto and Parallel pages run every frame through
  `Interpreter#update` (renamed internally to also call
  `#update_map_events`), the same auto-restarts-once-finished
  simplification already documented for Common Events. Confirm and
  Player-Touch/Event-Touch pages never start from `#update` -- only
  `WolfRPG::MapScene` calling `#trigger_confirm`/`#trigger_touch` (on a
  decision-key press against the faced or stood-on tile, and on a
  movement bump respectively) starts them, matching
  help/04eventwindowB.html's own trigger descriptions and mirroring
  `mruby-rpg2k`'s established `#touch_trigger?`/`#event_at`/`#start_event`
  precedent for the identical RPG2000/2003 trigger pair (a touch event
  fires on the bump attempt itself, independent of whether the step
  actually succeeds).
- **A second real bug**, found only once Confirm/Touch triggers were
  exercised against the sample game: `#update_map_events`'s original
  version only ever advanced a map event's `Run` while its *current*
  active page was Auto or Parallel, so a Confirm/Touch-triggered run that
  hit a `Wait` was never stepped again on a later frame (frozen forever,
  `done` staying false). Fixed by separating "should a new run start
  automatically" (Auto/Parallel only) from "should every already-live run
  keep advancing" (always, regardless of what started it) -- the same
  distinction Common Events' own `@common_runs` handling already made
  correctly from the start.
- **Movement blocking** (`Interpreter#blocking?`): true while any
  *non-Parallel* run -- an Auto-run Common Event or any map-event page
  other than Parallel -- is still executing, so the hero cannot wander off
  mid-event (help/04eventwindowB.html: "自動実行... 実行中は、他のイベン
  トは起動しません（並列実行のものを除く）"). `WolfRPG::MapScene#update`
  freezes movement and confirm-key handling while this holds, but still
  advances the interpreter every frame regardless, so a Parallel page
  never stalls on an unrelated Auto page elsewhere.
- **Rendering**: a colour-block marker per event with a currently-active
  page (visibility and position recomputed every frame, since a page's own
  conditions can change any time), the same fallback style
  `WolfRPG::MapScene`'s tiles already use pending real ChipSet-image
  rendering (`docs/TODO.md`).
- **`Interpreter#run_class`**: every `Run.new` call site (Common Event
  calls, map-event auto/parallel pages, Confirm/Touch triggers) now goes
  through this one factory method instead of a bare `Run.new`, so
  `scripts/wolf_interpreter_check.rb`'s soak check can install a
  step-bounded subclass for all of them by overriding just this method.
- **A third real bug**, found by that extended soak check once it started
  exercising Confirm triggers against every real map: the sample game's
  own "お店" (shop) event calls into a Common Event chain with a genuine
  cursor-input-wait loop (`StartLoop { ...; Wait(1) }`, exiting only on
  real player input this soak check cannot provide). The check's original
  safety net (`BoundedRun` capping the number of `#step`/`Fiber.resume`
  calls) could not catch this: the loop *does* yield every iteration via
  `Wait(1)`, so each individual `#step` call returns quickly and the total
  `#step` count only grows across `run_common_event`'s own unbounded
  `run.step while !run.done` drain loop, which never terminates because
  `done` never becomes true. Fixed by bounding total *dispatched commands*
  per `Run` instead (`BoundedRun#dispatch`, overriding the `Run` internal
  the count actually needs), which catches both a tight loop stuck inside
  one `Fiber.resume` and one spread synchronously across many. Hitting
  that cap from a one-shot Confirm/Touch exercise (as opposed to the
  per-frame auto/parallel loop, which has no such excuse) is treated as an
  expected, logged note rather than a check failure -- there is no real
  input for an automated soak check to satisfy.

## Consequences

- Every stationary map event with an Auto, Parallel, Confirm, or
  Player-Touch/Event-Touch page now actually runs its commands, using the
  same `VarStore`/self-variable machinery Common Events do (`Interpreter`
  tracks "current map event" the same way it already tracks "current
  common event").
- Event *movement* (custom/random/toward-hero move routes,
  `Wolf::Page#move_type`) is not implemented: every event stays at its
  parsed `(x, y)` for the whole session. This also means Event-Touch's own
  "the event walks into the player" half of its trigger cannot fire yet --
  only the player-initiated half does, which is a defensible subset since
  a stationary event's Event-Touch and Player-Touch triggers are
  observationally identical from the player's side.
- `CommonEvent`(210) targeting a *specific* map event's page (an
  `event_id` outside the 500000-599999 Common Event range) is still an
  explicit, logged no-op -- decoding that addressing scheme is unrelated
  scope, left for a follow-up.
- No map transition (Teleport) exists yet, so `Interpreter#current_map`
  is set once and never revisited; `@map_runs` and `VarStore`'s
  per-event self-variable banks (keyed by event id alone, not
  `(map_id, event_id)`) are both known to need reconsideration once one
  is implemented, since different maps reuse small event ids.
- `scripts/wolf_interpreter_check.rb` now also drives every real map's
  events (not just Common Events), for every map the project's own
  `MapTree` lists -- the same "must survive real data" bar the Common
  Event soak check already held itself to, extended to catch page-
  selection and trigger bugs the hand-built `mruby-wolf/test/wolf_test.rb`
  fixtures cannot reach on their own.
