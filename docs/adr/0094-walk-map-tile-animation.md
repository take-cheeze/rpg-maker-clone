# 94. Tile animation in the walk port, from mruby-rpg2k's own clocks

Date: 2026-09-07

## Status

Accepted

## Context

The walk port (ADR 61, ADR 91) has never animated. Its first slice froze
every tile at animation frame 0 and said so, and ADR 61 named the fix as a
bounded follow-up: "shipping multiple pre-composited frames per animated tile
id and cycling the atlas index."

Meanwhile three format revisions (ADR 92, ADR 93) cut the nano 7G's working
set from 344 KB to 108 KB. That headroom was the argument for stopping the
shrinking and spending it on features instead, and this is the first one.

The interesting part is not the pixels. RPG2000 animates two classes of tile
on two different clocks — the water autotiles in blocks A/B, and the block-C
animated tiles — with rules that are not obvious: the water's step is 12 or
24 frames depending on the chipset's `animation_speed`, and for
`animation_type` 0 it *ping-pongs* 0,1,2,1 rather than cycling 0,1,2, while
block C runs 0..3 every 6 frames. **mruby-rpg2k already implements all of
that**, in `Game::ChipsetLayout.anim_ab` and `.anim_c`, and the renderer
feeds their results straight into `quads(id, abf, cf)` — which this port's
exporter has been calling with `abf = cf = 0` since the beginning.

So the question was never "how does RPG2000 animate"; it was "how do we get
that answer onto a device with no interpreter".

## Decision

Format **v5**: a cell names an **entry**, and an entry is up to four atlas
slots plus the clock that moves through them.

- `map.bin` gains `atlas_count`, both clocks' step length and cycle length,
  and an entry table of `u8 frame[4] | u8 anim_class` (0 static, 1 water,
  2 block C). `tiles.bin` is unchanged in kind — still deduplicated
  pictures — it simply holds the extra frames.
- **The exporter asks the engine rather than restating it.** It probes
  `anim_ab`/`anim_c` for the frame at which each first changes (their step),
  then samples each at its own step boundaries and takes the shortest repeat
  (their cycle). Nothing in `scripts/export_nano7_map.rb` knows that water
  ping-pongs or that block C runs on sixes; a chipset this exporter has
  never seen still animates the way mruby-rpg2k would animate it.
- **A tile whose frames composite alike is recorded static.** A chipset that
  draws its water without animating it costs the device nothing at run time,
  and `rw_open` answers `m->animated` once so a still map costs the frame
  loop nothing at all — 477 of Nepheshel's 543 maps.
- **The device advances a counter.** `rw_set_frame(m, frame)` moves both
  clocks and returns whether either stepped; `rw_cell_animated` says which
  cells that affects, so an animation tick redraws the water and not the
  screen. That matters most on the Wio Terminal, where a full repaint is a
  320x240 frame over SPI.
- **`--no-animate`** exports every tile still, which is what v4 did. It is
  the fallback if an animated export ever exceeds a device's atlas cap, and
  the check asserts it is the animated export's phase 0 cell for cell rather
  than a different map.

### What it costs

Measured across all 543 Nepheshel maps, and on the nano app rebuilt against a
real NanoApps checkout with `arm-none-eabi-gcc` 13.2:

| | v4 | v5 |
| --- | --- | --- |
| nano 7G `.text` | 4,824 B | 5,304 B |
| nano 7G `.bss` | 108,396 B | 109,716 B |
| nano 7G packed `.hbapp` | 5,056 B | 5,536 B |
| atlas, Nepheshel map 1 | 137 pictures | 171 pictures (137 entries) |
| worst atlas in the test bed | 146 | **180** (map 236) |

480 bytes of code and 1.3 KB of RAM. The worst map in the whole test bed
needs 180 atlas slots against a 255 ceiling, and 66 of 543 maps animate
anything at all, so animation costs no map its place on either device — the
Wio's 192-slot cap still clears every one.

Verified by rendering the export at each phase: phase 0 is **byte-for-byte**
the v4 image (nothing still moved), phases 1 and 3 are identical to each
other and differ from phase 0 by the same 798 bytes, and phase 2 differs by
2,482 — which is `anim_ab`'s ping-pong showing through the file format.

## Consequences

- **The port has its first real game feature**, and got it by asking the
  engine rather than reimplementing it. That is the pattern for anything
  else worth adding here: the host runs mruby-rpg2k, the device indexes a
  table. Event sprites and the hero's own CharSet are the obvious next
  candidates and would work the same way — precomputed on the host, static
  on the device, because an event that *does* anything needs the
  interpreter.
- **The device now has a frame loop that does work between steps.** It is
  bounded (only cells the core reports as moving) and skipped entirely on a
  still map, but it is the first time this app draws anything the player did
  not ask for. A device measuring battery life will notice.
- **Only `animation_type` 0 / `animation_speed` 0 is exercised by the test
  bed**: every Nepheshel chipset uses it. The other paths are handled by
  construction — the export samples the real function rather than branching
  on the type — but no test data proves the 3-step cycle or the 12-frame
  step, and this ADR is where that is written down rather than assumed.
- **A fourth format revision in a day** is a lot of churn for anyone holding
  exported files; they are cheap to regenerate, and the on-device reader
  refuses an older version rather than misreading it.
