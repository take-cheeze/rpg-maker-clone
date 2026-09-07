# 69. WOLF RPG Editor event movement: Page#move_type and SetMoveRoute(201)

Date: 2026-09-07

## Status

Accepted

## Context

Every map event so far stayed exactly at its parsed start position: Page's
own `move_type` field (None/Custom/Random/TowardHero) and the explicit
"■動作指定" event command (`SetMoveRoute`, code 201, help/04ev_movesettingB
.html) were both fully *parsed* (ADR 0064's own framing already round-trips
a page's initial route and any inline one with nothing left over) but never
*run*. ADR 0068 left this as the suggested next slice after Picture(150)'s
file/shape rendering.

Two questions had to be answered before trusting a numeric RouteCommand id
at all:

- **Where a picture's filename resolves** was already settled (ADR 0068);
  the open question here was RouteCommand's own per-step `id`/argument
  meaning. Its *framing* is proven the same way Command's own framing is --
  WolfTL's `RouteCommand.hpp` reads the identical 1-byte id + 1-byte arg
  count + N ints + 2-byte terminator shape this reader already used, and the
  whole sample game's Common Events and map events parse with nothing left
  over either way. Its *meaning* is single-source: only the
  wolfrpg-map-parser crate models per-id semantics (its own `MoveType` enum),
  cross-checked here not against a second independent decoder (none exists)
  but against help/Ev_routeset.png's own Japanese button labels one id at a
  time -- "ランダム移動" next to `MoveRandom`, "主人公に接近" next to
  `MoveTowardHero`, "右に回転(45/90)" next to `TurnRight`, and so on for
  every id this reader implements.
- **Real command dumps surfaced ids the crate's own table has no entry
  for at all**: 21, 29, 47 and 60, found across the sample game's three
  `page.route`s and its one real `SetMoveRoute(201)` call (which targets the
  hero and carries exactly one of these, id 29). Rather than guess, every
  RouteCommand id without a cross-checked meaning -- these four, the four
  diagonal movement/facing ids (4-7/12-15, which would also need a diagonal
  passability model this reader does not have), and every setter/toggle id
  (speed/frequency/graphic/opacity/height/sound/variable/jump/
  approach-position) -- is logged and skipped. `RouteCommand`'s own framing
  already isolates each step's argument count regardless of whether its id
  is understood, so skipping one costs nothing structurally.
- **SetMoveRoute(201)'s own target field** ("動作指定する対象") is fully
  documented (same manual page): `>=0` an event id, `-1` this event, `-2`
  the hero (party leader), `-3..-7` party members 1-5 -- no party system
  exists yet, so that last band is logged and skipped like any other
  not-yet-modeled command, and it *was* the real one hit against the sample
  game's own single `SetMoveRoute` call (`-2`, the hero).
- **Randomness**: `MoveRandom`/`TurnLeftRightRandom`/`FaceRandomDirection`
  need to pick one option, and `Page#move_type`'s own Random/TowardHero need
  a periodic step. `Array#sample`/`Hash#key` turned out not to exist at all
  in this project's vendored mruby fork (confirmed empirically: using them
  here made `ctest -R mruby_test` raise `undefined method 'key' for Hash`
  and `'sample' for Array`), and `Kernel#rand` (via `mruby-random`) is a
  dependency this gem does not declare -- exactly the trap AGENTS.md's own
  "mruby stdlib methods live in core *-ext mrbgems" note describes, except
  that two of the three methods this reader first reached for are not even
  gems away, they are simply absent. mruby-rpg2k's own `Game::Rng` already
  solves the same problem with a tiny seeded LCG, kept for the same
  reason its own comment gives (a future frame-by-frame diff against a
  genuine reference) even though WOLF RPG Editor has no such reference yet
  (docs/adr/0064).

## Decision

- **Runtime position, separate from parsed data**: `Wolf::Interpreter`
  keeps one `{x:, y:, direction:, page_index:, move_timer:}` entry per map
  event id (`#event_position`), seeded from the event's own parsed start
  position on first use -- mirroring mruby-rpg2k's own `Game::Character`
  wrapper around its read-only `LcfMapEvent`, not mutating the parsed
  `Wolf::Event`/`Page` objects themselves. `#event_at` (passability/trigger
  lookups) and `WolfRPG::MapScene#update_events` (the event marker's own
  screen position) both switched from the event's static `x`/`y` to this.
  The hero's own position lives where it always has (`WolfRPG::MapScene`'s
  `@x`/`@y`); new `#x`/`#y`/`#hero_pos`/`#hero_pos=`/`#hero_at?`/`#passable?`
  accessors let Interpreter read and move it too, for `MoveTowardHero`/
  `SetMoveRoute(201)`'s own hero target.
- **`Page#move_type`**: `Custom` plays `page.route` once, the moment a page
  becomes the event's active one (tracked via `pos[:page_index]`) -- not
  every frame, and not on every `#update_event_movement` call while that
  page stays active. `Random`/`TowardHero` tick a step on a
  `#move_pause_frames(move_frequency)` cadence (not sourced from a numeric
  table -- no dropdown value list exists in help/*.html, only the
  qualitative "raising it shortens the pause" description -- a reasonable
  decreasing interval stands in). `TowardHero` falls back to a random step
  once the hero is further than `TOWARD_HERO_RANGE` tiles away, per the
  manual's own qualitative note that it does the same
  ("ただし、ある程度距離が離れるとランダム移動になります").
- **`SetMoveRoute(201)`**: `#exec_set_move_route` resolves its target
  (`#resolve_route_target`) to either a map event's own runtime position or
  the hero's, then runs the same `#run_route_commands` a Custom page's own
  route uses. A repeating route (`route_flags`/`route_options`'s own bit 0,
  cross-confirmed against the crate's own `Options` struct) is logged and
  skipped entirely rather than applied once and silently dropping the loop
  -- applying it *at all* here means instantly, snapping through every step
  with no gradual animation (the same simplification Picture(150)'s own
  Show/Move already make), so a real repeat would spin forever.
- **Cross-confirmed RouteCommand ids only**: the 4 cardinal movement/facing
  pairs (0-3/8-11), `MoveRandom`/`MoveTowardHero`/`MoveAwayFromHero`/
  `StepForward`/`StepBackward` (16-20), and `TurnRight`/`TurnLeft`/
  `TurnLeftRightRandom`/`FaceRandomDirection`/`FaceTowardHero`/
  `FaceAwayFromHero` (22-27). Anything else -- the four unplaced real ids
  (21/29/47/60), the four diagonal ids, and every setter/toggle id -- is
  logged and skipped.
- **`Wolf::Interpreter::Rng`**: a tiny seeded LCG (identical shape to
  mruby-rpg2k's `Game::Rng` -- multiplier 75, modulus the prime 65537) for
  every "pick one" this command needs, instead of `Array#sample`/
  `Kernel#rand`.
- Moving onto a tile checks the map's own passability and the hero's own
  tile (`current_scene.passable?`/`#hero_at?`) but not other events --
  unlike the hero's own `#move_hero`, nothing here stops two moving events
  from overlapping, and none of WOLF's own documented "自動移動" pathfinding
  variants (help/04eventwindowB.html's own "短距離"/"大負荷" auto-move modes)
  are modeled; only the direct, non-pathfinding step commands are.

## Consequences

- The sample game's own `Custom` pages (its title-screen decoration events)
  and its one real `SetMoveRoute(201)` call (the hero, via CE#48's basic
  system initialization) both run against the real binary with no crash and
  no exception -- the unconfirmed route id (29) that call actually carries
  logs and is skipped, exactly as designed, rather than mis-stepping the
  hero.
- `Random`/`TowardHero` movement is real but unverified against the sample
  game itself: none of its 4 maps use either `move_type` (confirmed by
  dumping every page's own `move_type` field), so this reader's own pacing
  formula and `TowardHero` range constant have no real-world example to
  check against, unlike the Custom-route ids above.
- Two-hop indirection is now unavoidable for anything that reads an event's
  position: `Wolf::Event#x`/`#y` remain the *parsed start* position, only
  `Interpreter#event_position` is current. A future save/load system will
  need to persist this runtime table, not the parsed data.
- Still unimplemented, logged rather than guessed: the four diagonal
  RouteCommand ids, every setter/toggle id (speed/frequency/graphic/
  opacity/height/sound/variable/jump/approach-position), a repeating
  route, a party-member `SetMoveRoute` target, and `CommonEvent`(210)
  targeting a specific map event's own page (ADR 0066's own gap, unrelated
  to this one).
