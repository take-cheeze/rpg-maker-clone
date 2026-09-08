# 102. The walk port draws map events, from each one's own initially-active page

Date: 2026-09-08

## Status

Accepted

## Context

ADR 94 named "event sprites and the hero's own CharSet" as the two obvious
candidates after tile animation; ADR 96 did the hero. Its own last line named
this one explicitly and why it needs its own ADR: an event's graphic can
change at runtime (Set Move Route "Change Graphic"), can be any of several
characters on a map rather than one fixed leader, and has no single "initial"
state analogous to the party's -- so "precomputed on the host, static on the
device" (ADR 94's own framing) needs its own answer for what "the" picture of
an event even means with no live game state to ask.

`mruby-rpg2k` already answers most of this. `Game::EventPage.select` is the
same "which page is active" logic `Scene::Map#build_event` calls, evaluated
against switches/variables/party state exactly like the real interpreter --
so a fresh, empty `Game::Switches`/`Game::Variables`/`Game::Party` (the same
"no live game state" limit ADR 96 already accepted for the hero) picks
whichever page a brand-new save would see, which for the overwhelming
majority of events (no switch has been touched yet) is also the page a
player actually meets first. `Game::EventGraphic.frame` is the same call
`build_event` makes for the walk-cycle frame, given a direction, a pattern,
and `moving: false` for a event that has not yet stepped.

One real trap surfaced while writing the export: `page.direction`'s own
schema.rb comment claims "2=down,4=left,6=right,8=up" (RPG Maker's numpad
convention, direct), but the actual runtime
(`mruby-rpg2k/mrblib/scene/map.rb`'s `page_direction`/`build_event`) treats
it as a raw 0..3 index converted through `Game::EventGraphic.numpad_direction`
-- the comment is wrong, the code it describes is not; this export follows
the code. A second, unrelated trap: `Game::Party.new(db)` with no explicit
`ids` defaults to `db.system.party`, and under plain CRuby (this script's
host) `db.system` resolves to `Kernel#system` before `method_missing` ever
sees it -- the same `db[22]`-vs-`db.player` trap ADR 96 already documents,
newly hit through a different call. Worked around the same way: pass the
already-computed party id list in explicitly.

## Decision

Format **v7**. The header grows from 26 to 29 bytes -- `event_count` (u16)
and `event_frame_count` (u8) -- rather than repurposing another byte the way
v6 did for `hero_present`: a v6 export has no spare byte left, and growing
the header outright costs nothing an in-place repurposing would have saved.
map.bin gains an `events` array (`event_count` entries, 4 bytes each: `x`,
`y`, `frame`, `layer`, all bytes) between the entry table and the cell
arrays; tiles.bin gains `event_frame_count` more 24x32 frames -- the hero's
own `RW_EVENT_FRAME_W/H` alias -- appended after the hero's own 12 (if
present), never conditional on it the other way around.

- **An event is exported when its initially-active page has a CharSet
  graphic.** `Game::EventPage.select` picks the page against a fresh
  switches/variables/party state (see Context); a page with no graphic, or
  whose graphic is a chipset tile (`Game::EventGraphic`'s other kind, a
  16x16 chip rather than a 24x32 CharSet frame) is skipped entirely -- not
  an error, the same "missing is not a bug" call ADR 96 made for a hero-less
  project. Chip-graphic events are a real, explicit gap, left for their own
  future format revision (see Consequences).
- **One frame each, picked once, never animated on-device.** The direction
  is the page's own base facing, the pattern its own base pattern,
  `moving: false`, `phase: 0` -- `Game::EventGraphic.frame`'s own answer for
  "an event that has just spawned and has not stepped," matching the walk
  port's existing rule that anything requiring live simulation (a Fixed
  Continuous event mid-animation, a Spin event's live orientation) is
  flattened to its resting frame. An event's own opacity/blend page setting
  is not read either -- a half-opacity page draws fully opaque, the same
  simplification the hero's own compositing already makes.
- **Frames are deduplicated the same way tile pixels and hero frames are.**
  Many events on one map commonly share a picture (Nepheshel's own data:
  256 events on its worst map, 12 distinct pictures), so the atlas is sized
  by distinct pixels, not by event count -- `max_event_frames` (64 nano7, 16
  Wio) bounds the atlas itself, `max_events` (1024, both targets) bounds the
  event table, which costs only 4 bytes each and so gets a much more
  generous cap than the picture atlas's real RAM pressure allows.
- **Draw order is `Scene::Map`'s own `event_target_buffer` rule, not
  invented here.** A `layer` byte on each event (0 below / 1 same / 2 above,
  `RW_EVENT_LAYER_*`) mirrors the page's own "below characters / same as
  characters / above characters" setting; below always draws under the
  hero, above always over, and same-as-hero further splits by row exactly
  like the genuine renderer: `event_y < player_y` draws under, `event_y >=
  player_y` draws over. `rw_event_before_hero` answers this per event; both
  device apps draw every "before" event, then the hero, then every "after"
  one. Same-layer relative order among events sharing a side is the
  renderer's own y-then-x sort (`Scene::Map#draw_events`'s own
  `sort_by { |e| [e[:char].y, e[:char].x, e[:id]] }`) -- done once at export
  time (`events_out.sort_by! { |x, y, _frame, _layer| [y, x] }`), not
  on-device, so a device reader that just walks the array in stored order
  gets it for free.
- **The device composites and positions an event exactly like the hero,
  with no new code shape.** `rw_compose_event` is `rw_compose_hero` with a
  frame-index bounds check instead of a walk-cycle lookup (transparent stays
  transparent, over the map, not into a hole); `rw_event_screen_pos` is
  `rw_hero_screen_pos`'s own centred-horizontally/bottom-anchored formula,
  at the event's own cell instead of the player's. Both device apps' draw
  loops gained the same one-opaque-pixel-at-a-time blit the hero already
  uses, no new primitive.

### What it costs

Measured on a real rebuild of both device apps, v6 (ADR 96, hero sprite)
against v7:

| | v6 | v7 | delta |
| --- | --- | --- | --- |
| nano 7G `.text` | 5,552 B | 6,024 B | +472 B |
| nano 7G `.bss` | 120,484 B | 175,284 B | +54,800 B |
| nano 7G packed `.hbapp` | 5,788 B | 6,268 B | +480 B |
| Wio Terminal RAM | 112,092 B (57.0%) | 130,032 B (66.1%) | +17,940 B |
| Wio Terminal flash | 71,984 B (14.2%) | 72,464 B (14.3%) | +480 B |

The nano's `.bss` jump is almost entirely the event-frame atlas reserved
unconditionally at its full `max_event_frames` (64 frames x 768 bytes) plus
the event table at its full `max_events` (1024 x 4 bytes) -- the same
"a fixed cost beats a second size to get right" call v5 and v6 both made,
extended to a much larger per-target ceiling because an event table costs
so little per entry that there was no reason to cap it tightly. The nano
budget (`app/nano7/rpg2k_walk/rpg2k_walk.c`'s own header comment) and the
Wio one (`app/wio/src/walk_main.cxx`'s) are both updated with these real,
measured numbers, not estimates.

## Consequences

- **Verification is real, on real data.** `scripts/export_nano7_map_
  check.rb` gained checks that `event_count`/`event_frame_count` stay
  within each target's caps, every event's cell is on the map, every
  event's frame index and layer are valid, the event table is pre-sorted by
  `(y, x)`, event frame pictures are deduplicated, and tiles.bin's size
  accounts for the event atlas on top of the ordinary one and the hero's --
  run against the default 5-map sample (162 checks, 0 failures) and again
  against a wider every-15th-map sweep (37 maps, 1,156 checks; the only 3
  failures are the same two oversized maps this test-bed's default sample
  already knows exceed the 128x128 on-device cap, correctly refused, plus
  the pre-existing `--no-animate` bug below, none of them this ADR's own
  logic). A full sweep of all 543 maps through the plain exporter (not the
  fuller check script) confirms the real-world shape this format targets:
  the worst map carries 256 sprited events reducing to 12 distinct frames,
  both comfortably inside the chosen caps. `walk_core_test.c` gained 18 new
  synthetic checks -- a `test_events` function covering frame selection,
  layer-vs-row draw order, compositing, and screen position exhaustively,
  plus three new truncation checks in `test_open` for the event table and
  its frame atlas -- 1,637 checks total, 0 failures.
- **A pre-existing, unrelated bug resurfaced while sweeping maps for this
  ADR, already documented by ADR 96 and not introduced here** (confirmed
  identically reproducible against the unmodified v6 exporter, stashed back
  to verify): map 124's `--no-animate` export is not byte-for-byte the
  animated export's own phase 0. This is the same defect ADR 96's own
  Consequences section already named (19 of 543 maps, a real
  animation-cycle-detection bug worth its own follow-up, not blocking here
  since the default 5-map sample this check runs by default does not
  include it).
- **Chip-graphic events (a 16x16 chipset tile instead of a CharSet frame)
  are not exported at all**, a real and explicit gap: `Game::EventGraphic`'s
  other kind reuses the ordinary tile atlas geometry rather than the
  hero's, and would need its own atlas-slot reuse logic to draw cheaply
  (unlike a CharSet frame, a chip-graphic event's picture is *already* in
  the map's own tile atlas most of the time) -- left for a future format
  revision rather than folded in here as a special case.
- **An event's graphic never changes on-device**, the same limitation the
  hero's own static export already accepts: a Set Move Route "Change
  Graphic" command, a self-switch flipping an event to a different page
  mid-game, or a Show/Erase Event command are none of them reflected --
  this is a snapshot of a fresh save's first look at the map, not a live
  simulation of anything an interpreter would need to run.
