# 96. The walk port draws the hero's own CharSet, from mruby-rpg2k's own geometry

Date: 2026-09-07

## Status

Accepted

## Context

ADR 94 named the obvious next candidate after tile animation: "Event sprites
and the hero's own CharSet... would work the same way — precomputed on the
host, static on the device, because an event that *does* anything needs the
interpreter." The walk port has drawn the player as a plain red disc since
ADR 61's first slice; every other visible thing on screen is now real RPG
Maker art.

The geometry is not obvious either. A CharSet PNG holds **eight** character
templates in a 4×2 grid, each three walk frames wide by four directions
tall, each frame 24×32 — bigger than the 16×16 tile grid this port already
draws, so the hero cannot be "one more atlas tile." Its facing follows
RPG2000's numpad convention, its walk cycle steps through frames 1,2,1,0 (a
neutral pose bracketed by two lean poses, not a naive alternation), and a
blocked step still turns the character to face it (confirmed by reading
`Scene::Map#step_movement`: `@state.direction = dir` runs *before* the
passability check and is never reverted). `mruby-rpg2k` already has all of
this in `Game::CharSet` and `Scene::Map`'s own render path — the same
"ask the engine" pattern ADR 94 established for tile animation.

## Decision

Format **v6**. A cell's shape does not change; the header's unused pad byte
(byte 5, zero since v1) becomes `hero_present`, and when it is 1, `tiles.bin`
carries 12 more 24×32 frames after the ordinary atlas — `[direction][pattern]`
order, a fixed 9,216 bytes whether or not a given export actually has a hero,
which is simpler and cheaper than a second size to get right.

- **The hero is the project's own *initial* party leader** — `RPG_RT.ldb`'s
  `System.party` (first entry) and that actor's own `charset_name`/
  `charset_index` (`db[22]`/`db.player`, not `db.system`/`.player` under
  CRuby: `system` resolves to `Kernel#system` before `method_missing` ever
  sees it, the same trap AGENTS.md already documents for `save[101]`). There
  is no live game state a host-side export can ask instead, so a Change
  Hero Graphic command or a title-screen event that assembles the real party
  later is not reflected — the same kind of limitation the export's own
  parallax-to-backdrop reduction already accepts.
- **Missing or blank is not an error.** Unlike a missing chipset, a hero
  sprite is an enhancement over the port's original marker; a small or
  custom project with no static leader graphic exports exactly as it did
  before this format version. This is not a hypothetical: Nepheshel's own
  default party leader is a blank-charset placeholder row (confirmed by
  `mruby-lcf`'s own `SAVE_PARTY_ACTOR` schema comment) — its real sprite,
  "mainchr" index 4, is assigned by a runtime Change Sprite Association
  event, which is exactly the kind of thing this static export cannot see.
  All 543 of its maps export hero-less, byte-for-byte the same map.bin/
  tiles.bin content this format's tile data already produced.
- **The device composites the hero the way it composites a tile, with one
  real difference.** `rw_compose_hero` resolves palette indices into
  ARGB1555 exactly like `rw_compose_cell`, but a transparent source pixel
  stays 0 instead of resolving to the backdrop: a hero frame draws *over*
  cells the map loop already drew, not into a hole that needs filling. Both
  device apps blit it pixel by pixel with a transparency skip — nano7 writes
  its own framebuffer directly (`hb_raw_blit` copies a whole rect
  unconditionally), the Wio Terminal calls `drawPixel` per opaque pixel —
  since neither platform's existing rect-blit primitive has a transparency
  test.
- **The screen position is the genuine renderer's own formula.**
  `rw_hero_screen_pos` is `Scene::Map#render`'s
  `px - (WIDTH-TILE)/2, py - (HEIGHT-TILE)`: centred horizontally over the
  player's tile, bottom-anchored to it — the sprite overhangs a 16px tile by
  4px a side and 16px above, which is why it needs its own position
  function rather than reusing a cell's.
- **The walk cycle and bump-turn are core state, not device state.**
  `rw_map` gains `direction` (numpad convention) and `step_count`.
  `rw_try_move` turns to face the attempted direction *before* checking
  passability and leaves it turned on a blocked step, matching
  `step_movement` exactly; only a successful step advances `step_count`,
  which `rw_compose_hero` uses to pick the walk-cycle phase (`moving` — a
  direction currently held — is the one thing the core cannot know for
  itself, so it is the caller's own input state, passed in explicitly).

### What it costs

Measured on the nano app rebuilt against a real NanoApps checkout with
`arm-none-eabi-gcc` 13.2:

| | v5 | v6 |
| --- | --- | --- |
| nano 7G `.text` | 5,304 B | 5,552 B |
| nano 7G `.bss` | 109,716 B | 120,484 B |
| nano 7G packed `.hbapp` | 5,536 B | 5,788 B |

248 bytes of code and 10,768 bytes of RAM — almost all of it the hero's own
fixed 9,216-byte frame block, reserved unconditionally on both devices
whether or not a given export actually carries a hero, the same "a fixed
cost beats a second size to get right" call format v5 made for the
animation table.

## Consequences

- **Verification here is real but incomplete in one specific way.** This
  repo's own RPG2000/2003 test data has no project whose *initial* party
  carries a static CharSet: Nepheshel's is the runtime-assigned placeholder
  above, and mtf-meido-action (fetched to check) has a real one
  (`mitsuki_normal`) but chipsets that are not the 256-colour PNGs this
  exporter requires at all, so no map from it exports successfully by any
  path. `scripts/export_nano7_map_check.rb` therefore verifies the DB-driven
  leader lookup and the hero-less case against 543 real maps, and verifies
  the frame geometry and pixel decode — the same `Game::CharSet.frame_rect`
  and colour-keyed PNG load the export path calls — independently, against
  Nepheshel's own real `mainchr.png` at its confirmed real index. The one
  thing neither check exercises is both halves at once: a real database's
  `System.party` pointing at an actor whose own `charset_name` is already
  populated. `walk_core_test.c`'s 24 new synthetic checks cover the
  frame-selection and compositing logic exhaustively; the gap is
  specifically in the LCF/database plumbing on top of it.
- **A pre-existing, unrelated bug surfaced while surveying all 543 maps for
  this ADR**, not introduced by it (confirmed reproducible identically
  against the unmodified v5 exporter): 19 maps' `--no-animate` export is not
  byte-for-byte the animated export's phase 0, contradicting the invariant
  ADR 94's own check asserts. The curated 5-map sample `export_nano7_map_
  check.rb` runs by default (and CI with it) does not include any of the 19,
  so this does not block anything here, but it is a real defect in the
  animation-cycle detection worth its own follow-up.
- **Event sprites are the next candidate ADR 94 named alongside this one**,
  and would need more than this ADR's shape: an event's own graphic can
  change at runtime (Set Move Route "Change Graphic"), can be any of several
  characters on a map rather than one fixed leader, and has no single
  "initial" state analogous to the party's. Left for its own ADR.
