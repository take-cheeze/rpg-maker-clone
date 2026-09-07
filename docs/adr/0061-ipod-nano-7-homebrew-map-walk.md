# 61. A minimal, non-mruby map-walking port for iPod nano 7th generation

Date: 2026-08-27

## Status

Accepted

## Context

A core project goal (see ADR 1) is to run RPG Maker games "on any environment
such like embedded boards." Every existing real-hardware port — Wio Terminal
(ADR 7), PSP (ADR 10), Android (ADR 58) — follows the same shape: add a new
LVGL display + input backend behind the seams `mruby-rgss` already exposes
(`rgss_set_display`, the per-frame poll hooks in `gfx_update`), and run the
*same* mruby interpreter and RGSS/RPG2k Ruby game logic this repo runs
everywhere else. That pattern only works when the target can host a
general-purpose interpreter and a few MB of compiled gem code.

The **iPod nano 7th generation** cannot. As of 2026 there is a real,
maintained homebrew scene for it:

- [`ipod_sun`](https://freemyipod.org/wiki/Main_Page) /
  [Pixosn0w](https://github.com/IAmDazen/Pixosn0w) give untethered code
  execution on the device.
- [NanoApps](https://github.com/nfzerox/NanoApps) is a public C SDK
  (`hb_sdk.h`) for building Home-Screen apps, built on **LVGL** — the exact
  display library the other ports already use.

But NanoApps caps a homebrew app's **compiled, uploaded image** (`.text` +
`.rodata`, what its resident loads and I-cache-invalidates before jumping to
it) at roughly **500 KB**; past that, apps hang or crash on launch in ways
that are easy to misread as unrelated bugs (`sdk/hb_app.mk`'s own comment on
the ceiling). This repo's `libmruby.a` is 51–61 MB unstripped for every
existing cross target, and the PSP's `EBOOT.PBP` — mruby + the RGSS/RPG2k
gem stack + LVGL + engine — is 19 MB. Even after aggressive stripping and
`--gc-sections`, that gem stack is not landing under 500 KB; the gap is
40x+, not something `-Os` closes. Running the actual interpreter and Ruby
game logic on this device is not feasible with this engine's current
architecture.

A critical mitigating detail, confirmed empirically (see Decision): the
500 KB ceiling is specifically the **relocatable app blob** NanoApps' loader
places into RAM — `.bss` and anything read from the iPod's own filesystem at
runtime (`hb_fs_read`/`hb_bmp_load_to`) are outside it. So a large *runtime*
data set is free; only the *code* has to be tiny.

## Decision

Add a **from-scratch, non-mruby map-walking app**
(`app/nano7/rpg2k_walk/rpg2k_walk.c`) instead of a new mruby/RGSS backend.
This is a deliberate departure from every other port's pattern: it is a
different, much smaller engine, written directly in C against NanoApps'
`RAW_SURFACE` (direct-framebuffer) surface — not an additive display backend
to the existing interpreter. Scope is map walking only: tile rendering
(including autotiles) + grid movement + collision, for one static map. No
events, no interpreter, no battle/menus, no RGSS. It still renders real RPG
Maker 2000/2003 map data, not synthetic test data.

The pieces:

- **Host-side exporter** (`scripts/export_nano7_map.rb`): plain CRuby,
  loaded the same way `scripts/lcf_save_check.rb`/`lcf_testbed_check.rb`
  already load `mruby-lcf/mrblib/{lcf,schema}.rb` under CRuby with no mruby
  build. It also loads `mruby-rpg2k/mrblib/game.rb` for `Game::ChipsetLayout`
  (the tile-id → chipset source-rect geometry, including the autotile
  quarter-tile assembly — the exact module `scripts/rpg2k_render_check.rb`
  already exercises standalone) and `Game::ChipSet` (passability), and
  `scripts/rgss_cruby_compat.rb` for `RGSS::Bitmap`'s pure-Ruby PNG decoder.
  All LCF parsing and chipset compositing happens once, on the host, using
  the same logic the real engine uses — not a reimplementation of it.
- **Output format**: `map.bin` (dimensions, start position, backdrop colour,
  per-cell lower/upper tile-atlas indices, and a precomputed 4-bit-per-cell
  passability mask — both halves of `Scene::Map#char_passable?`'s check,
  "can this cell be exited this way" and "can the target cell be entered
  from the opposite side," baked in at export time) and `tiles.bin` (a flat
  ARGB1555 atlas, one 16×16 entry per distinct *composited result* the map
  actually uses, each built via `Game::ChipsetLayout.quads` at animation
  frame 0). The on-device C code never parses LCF, never assembles a
  quarter-tile autotile, and never computes passability — it reads two flat
  files and indexes arrays.
- **Transparency is one bit per pixel** (format v2). RPG Maker's chipset
  transparency is a colour key — palette index 0 — so a pixel is either drawn
  or absent, and 16-bit ARGB1555 carries that in the space 32-bit XRGB8888
  spent on an alpha channel nothing needed, halving both the file and the
  atlas in `.bss`. The device merges a cell's two layers into one composited
  tile before blitting, which is what lets an upper tile's transparent
  pixels show the lower tile through them.
- **On-device app** (`app/nano7/rpg2k_walk/`, since ADR 91 the NanoApps half
  of it, over the shared core in `app/shared/rpg2k_walk`): a `RAW_SURFACE`
  NanoApps app
  (`hb_raw_init`/`hb_raw_frame`) that loads both files via `hb_fs_read` into
  static `.bss` buffers, blits the visible viewport (one composited tile per
  cell, camera clamped to map bounds), and steps the player one tile at a time on
  continuous zone-hold touch input (a whole-screen virtual joystick, the
  input convention `apps/tetris`/`apps/paint` already use in NanoApps —
  N7G has no D-pad).
- **Size budget, verified**: `MAP_MAX_W`/`MAP_MAX_H` = 128, `MAX_TILES` = 256
  (mirrored between the exporter and the C bounds, so an oversized map is
  refused at export time rather than truncated or overflowed on-device).
  Built for real against a scratch NanoApps checkout with `arm-none-eabi-gcc`
  when this ADR was written: the linked `.text` was **4.3 KB**, `.bss`
  **336 KB**, and the packed `.hbapp` NanoApps' loader actually uploads
  **4.5 KB** — under 1% of the 500 KB ceiling, and `.bss` sits comfortably
  below the ~512 KB gap between `BSS_VA` and `LINK_VA` in `sdk/hb_app.mk`
  (that gap is not a documented hard cap, so the caps above deliberately
  leave headroom rather than target it exactly). Format v2's 16-bit tiles cut
  `.bss` to **214,628 B**, measured by rebuilding both versions against a
  NanoApps checkout with the same `arm-none-eabi-gcc`: `.text` 4,291 -> 4,712
  B and the packed `.hbapp` 4,551 -> 4,940 B, so 421 bytes of compositing
  code buys 127 KB of working set (see ADR 91, which also moved the engine
  half of this app into a core the Wio Terminal shares).
- **No CI job.** CI has no NanoApps toolchain and no iPod; unlike the PSP
  port's best-effort `psp-smoke` job there is not even an emulator to boot
  this under. `scripts/export_nano7_map_check.rb` (round-trips the exporter
  against the real Nepheshel test-bed data already in `data/`, including a
  positive check that an oversized map is refused) is the only automated
  coverage; the on-device build and hardware behavior are manual, documented
  in `app/nano7/rpg2k_walk/README.md`.

## Consequences

- This is the first port in the repo that does **not** extend the shared
  mruby/RGSS engine — a reviewer comparing it to ADR 7/10/58 should expect a
  different shape, not a missing display backend. Any future RPG2k feature
  work (events, battle, ...) added to the main engine does not reach this
  app; it would need its own, separate C implementation, which is a real
  cost of this approach and the reason the README frames it plainly as
  "walk a map," not "play the game."
- Because chipset compositing happens at export time, adding **tile
  animation** on-device would mean shipping multiple pre-composited frames
  per animated tile id and cycling the atlas index in `rpg2k_walk.c` — a
  bounded, scoped follow-up, not a re-architecture.
- **Multiple maps / map transitions** would need either bundling several
  `map.bin`/`tiles.bin` pairs and a simple on-device map-switch (still no
  interpreter) or accepting a NanoApps relaunch per map; not attempted here.
- Verified on a real jailbroken nano 7G: NanoApps installs the app, the
  exporter's `map.bin`/`tiles.bin` load correctly via `hb_fs_read`, tile
  rendering and grid movement/collision work, and touch-hold steps the
  player as designed.
- **The magenta-cell bug is fixed.** It was recorded here as a known bug
  with the root cause not yet isolated; it was not a tile id or a
  `Game::ChipsetLayout.quads` gap. `composite_tile` loaded the chipset
  through `RGSS::Bitmap#_init_file` **without** RPG Maker's colour-key flag,
  the one `Scene::Map#load_chipset_graphic` passes for the real renderer
  (`Bitmap.new "ChipSet/#{name}", true`). Palette entry 0 therefore exported
  as an ordinary opaque colour — (255, 103, 139) on Nepheshel's chipsets,
  exactly the magenta seen on-device — across 15.7% of map 1's exported
  atlas. The export now passes the flag, carries the resulting one-bit
  transparency through the atlas, and the app composites the layers
  on-device; `scripts/export_nano7_map_check.rb` reads the palette out of
  the very chipset the exporter reports using and fails if any opaque atlas
  pixel is that colour key again.
- **A transparent chipset region is legitimate, and needs a backdrop.**
  Isolating that bug turned up why those cells are keyed at all: Nepheshel's
  map 1 is an island whose entire sea is water autotile id 0 over an empty
  block A, with the sea drawn by the map's `BG` **parallax background** —
  and `Game::ChipsetLayout.block` already documents id 0 as *not* being
  empty. Honouring the colour key alone would only have swapped magenta for
  black holes. A whole panorama does not fit this device's budget, so the
  exporter reduces it to its average colour (a `u16` in `map.bin`'s header,
  (24, 74, 198) for that map) and the app paints that behind the map.
  Per-pixel parallax stays out of scope.
