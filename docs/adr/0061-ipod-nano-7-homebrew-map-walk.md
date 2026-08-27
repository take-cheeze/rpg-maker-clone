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
- **Output format**: `map.bin` (dimensions, start position, per-cell lower/
  upper tile-atlas indices, and a precomputed 4-bit-per-cell passability
  mask — both halves of `Scene::Map#char_passable?`'s check, "can this cell
  be exited this way" and "can the target cell be entered from the
  opposite side," baked in at export time) and `tiles.bin` (a flat XRGB8888
  atlas, one 16×16 entry per distinct tile id the map actually uses, each
  composited via `Game::ChipsetLayout.quads` at animation frame 0). The
  on-device C code never parses LCF, never assembles a quarter-tile
  autotile, and never computes passability — it reads two flat files and
  indexes arrays.
- **On-device app** (`app/nano7/rpg2k_walk/`): a `RAW_SURFACE` NanoApps app
  (`hb_raw_init`/`hb_raw_frame`) that loads both files via `hb_fs_read` into
  static `.bss` buffers, blits the visible viewport (lower then upper layer,
  camera clamped to map bounds), and steps the player one tile at a time on
  continuous zone-hold touch input (a whole-screen virtual joystick, the
  input convention `apps/tetris`/`apps/paint` already use in NanoApps —
  N7G has no D-pad).
- **Size budget, verified**: `MAP_MAX_W`/`MAP_MAX_H` = 128, `MAX_TILES` = 256
  (mirrored between the exporter and the C bounds, so an oversized map is
  refused at export time rather than truncated or overflowed on-device).
  Built for real against a scratch NanoApps checkout with `arm-none-eabi-gcc`
  in this session: the linked `.text` is **4.3 KB**, `.bss` is **336 KB**,
  and the packed `.hbapp` NanoApps' loader actually uploads is **4.5 KB** —
  under 1% of the 500 KB ceiling, and `.bss` sits comfortably below the
  ~512 KB gap between `BSS_VA` and `LINK_VA` in `sdk/hb_app.mk` (that gap is
  not a documented hard cap, so the caps above deliberately leave headroom
  rather than target it exactly).
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
- **Known bug, not yet fixed**: `composite_tile` in
  `scripts/export_nano7_map.rb` copies chipset pixels for every referenced
  tile id with no transparency handling. Cells whose tile id resolves to the
  chipset's transparent/placeholder region (confirmed on real map data, not
  just theoretical) render as solid magenta on-device instead of being
  skipped or resolved to something sensible. Root cause not yet isolated to
  a specific tile id or `Game::ChipsetLayout.quads` gap — tracked as
  follow-up work, not fixed in this slice.
