# RGSS2 / RGSS3 API gap for VX and VX Ace

The [RGSS script host](adr/0017-rpgxp-rgss-script-host.md) runs a project's own
script bundle unmodified. A VX / VX Ace game needs that more than an XP one
does: its **entire engine** is the bundle (`rgss_main { SceneManager.run }` is
the whole `Main` section), so there is no half-way point where a reimplemented
title/map flow gets a real game running. What the scripts assume is the RGSS2 /
RGSS3 class library, normally `RGSS200J.dll` / `RGSS300.dll`; this project
supplies it as `mruby-rgss` (plus the RGSS2/RGSS3-only pieces in
`mruby-rpgvx/mrblib/rgss2_runtime.rb`).

This document is the VX/VX Ace counterpart of
[`rpgxp-rgss-api-gap.md`](rpgxp-rgss-api-gap.md): **what the stock scripts call**
versus **what we provide**.

## How the "needed" column was measured

Against the **stock VX Ace script set** — 109 sections, ~19.9k lines, the same
scripts every new VX Ace project ships with (the `rgss3_default_scripts`
distribution of them; nothing is vendored into this repo). Counting
method/`.new`/constant usage across the bundle gives the frequencies below.

Two caveats, the same ones the XP document carries:

- The counts are name-based, so a name that several classes share (`tone`,
  `opacity`, `ox`, `padding`) is an upper bound rather than a per-class figure.
  They are meant to rank the work, not to be exact.
- `Main` is not part of the published set, so `rgss_main` shows up zero times
  here despite being in every real project. It is implemented regardless.

The measurement is also the reason this list is worth trusting over a reading of
the reference manual: it says what a game actually touches on the way to its
first frame, not what RGSS3 defines.

## Provided ✅

- **Value types** — `Table`, `Color`, `Tone`, `Rect` (native, with RGSS
  `Marshal`), shared with the XP path.
- **Data classes** — the whole RGSS2/RGSS3 `RPG::*` schema
  (`mruby-rpgvx/mrblib/rgss2_data.rb`, ADR 0024), so `load_data` returns typed
  records.
- **`Bitmap`** — `new` (~13), `draw_text` (~55), `fill_rect` (~14), `text_size`
  (~8), `gradient_fill_rect` (~5), `blt` (~3), `clear_rect` (~2), `get_pixel`
  (~2), `stretch_blt`, `hue_change`, `clear`, `font`, `dispose`. _Complete for
  the stock scripts bar the two blurs below._
- **`Font`** — instance attributes plus the class defaults the scripts read
  (`default_size`, `default_bold`, `default_italic`).
- **`Input`** — **RGSS2/RGSS3 spell keys as symbols** (`Input.trigger?(:C)`), and
  the stock scripts use nothing else: `:C` ×11, `:UP`/`:DOWN` ×7, `:B`/`:LEFT`/
  `:RIGHT` ×6, `:A` ×5, `:L`/`:R` ×4, `:CTRL` ×2, `:F9` ×1 — zero uses of XP's
  integer constants. `Input.press?`/`trigger?` (~30)/`repeat?` (~21)/`update`/
  `dir4` now take either spelling (`RGSS::Input::SYMBOL_KEYS`), so the same key
  table serves all three makers and the C++ input bridge is untouched.
- **`Graphics`** — `width` (~50) / `height` (~32) (declared by each maker's boot
  shell through `resize_screen`; VX is 544×416), `wait` (~2), `fadeout` (~3),
  `fadein`, `brightness` (~3), `frame_count`, `frame_rate`, `update`. The waits
  run real frames, so a scene that holds for a fade takes the right time.
- **`Audio`** — `bgm`/`bgs`/`me`/`se` `play`/`stop`/`fade` (+ `bgm_pos`/
  `bgs_pos`) resolved through `GAME_DIR`/`RTP_DIR`, and `setup_midi`.
- **`RPG::BGM`/`BGS`/`ME`/`SE` playback** — the records play *themselves* in
  RGSS2/RGSS3 (`$game_system.battle_bgm.play`): `#play` (~19), `#fade` (~6),
  `#replay` (~3) and the class-side `last` / `stop` / `fade` (~20 together),
  including the "empty name stops the channel" rule and the `last` slot a save
  restores from (`mruby-rpgvx/mrblib/rgss2_runtime.rb`).
- **`Window`** — the RGSS1 surface (`contents` ~84, `active` ~19, `cursor_rect`
  ~9, `contents_opacity`, `windowskin`, `back_opacity`, `pause`, `opacity`,
  geometry, `update`) plus the RGSS2/RGSS3 additions the scripts drive:
  `openness` (~16) with `open?`/`close?` (~15), `padding` (~6) /
  `padding_bottom` (~2), `arrows_visible`, `tone`, and the **VX-shaped
  constructor** `Window.new(x, y, width, height)` alongside XP's optional
  viewport.
- **`Viewport`** — `new` (~9), `ox`/`oy`, `rect`, `z`, `visible`, `update`,
  `dispose`.
- **`Sprite`/`Plane`** — the extended properties the scripts set are stored and
  (per the XP document) largely rendered: `opacity` (~41), `ox`/`oy` (~64),
  `blend_type` (~19), `zoom_x`/`zoom_y` (~24), `angle` (~10), `mirror` (~9),
  `src_rect` (~8), `bush_depth` (~5), `flash`.
- **Kernel** — `load_data` (~28) / `save_data` from the script host, `rand`
  (~37) from the core, and the RGSS2/RGSS3-only `rgss_main`, `rgss_stop`,
  `msgbox` (~2) and `msgbox_p`.

## Gaps (ordered by how much they block a playable VX game)

### 1. `Tilemap` — the VX map now draws ✅

`Spriteset_Map` builds the map with the RGSS2/RGSS3 tilemap:

```ruby
@tilemap = Tilemap.new(@viewport1)
@tilemap.map_data  = $game_map.data
@tilemap.bitmaps[i] = Cache.tileset(name)   # nine sheets: A1-A5, B-E
@tilemap.flags     = @tileset.flags         # the 8192-entry Table
```

`mruby-rgss`'s `Tilemap` was the XP one — `tileset=` (one sheet), `autotiles`
(seven), `priorities`. It now also speaks VX: `bitmaps` (the nine sheets,
assigned by index the way the scripts do it), `flags=`, and the VX tile-id
decode. A tilemap handed any sheet is drawn the VX way; the XP path is
untouched.

The decode is the interesting half. A VX tile id carries both *which* autotile
and *which of its edge shapes* to assemble from four quarter-tiles, with a
different sheet layout per family (A1 water/waterfall with its animation cycles,
A2 ground with the "table" split, A3 buildings and the A4 wall rows on 16 shapes
instead of 48, A5 and the B–E pages as plain tiles). It is ported from the
MIT-licensed MV corescript, which inherited VX Ace's tile system unchanged, and
**differentially tested against it**: all 8300 tile ids × a full animation cycle
× the table flag — 66,400 cases — produce byte-identical geometry.
`Tilemap.vx_tile_quads` exposes the decode so `mruby-rgss/test` pins it without
needing a display, both as representative cases and as a checksum over the whole
sweep.

Remaining polish: `flags` bit 0x10 routes a tile to the existing "above the
characters" layer, which is the same flat approximation ADR 0022 describes for
XP, and the A2 table-edge tile drawn *below* its neighbour
(`Tilemap#_drawTableEdge`) is not done.

### 2. `Viewport` screen effects — tint, flash and fade all draw ✅

VX/VX Ace do every screen effect through the viewport, not a sprite overlay:

```ruby
@viewport1.tone.set($game_map.screen.tone)              # tint          ✅
@viewport2.color.set($game_map.screen.flash_color)      # flash         ✅
@viewport3.color.set(0, 0, 0, 255 - $game_map.screen.brightness)  # fade ✅
viewport.flash(timing.flash_color, timing.flash_duration)  # animations ✅
```

**`Viewport#color` and `#flash` are implemented natively**: a colour overlay
canvas the size of the viewport, held above its content layer and refreshed from
`#update` — which is what makes the scripts' in-place `color.set(...)` visible,
since they mutate the Color object and call `update` every frame. It is the same
"screen-sized colour at an opacity" mechanism ADR 0021 measured working for the
RPG2000 fade, moved into the viewport so it clips, scrolls and hides with it. So
the **screen fade** (`Graphics.fadeout`/`fadein` via viewport3), the **flash**,
and **animation flashes** all reach the display.

**`tone` is implemented too, by a different mechanism.** Unlike `color`, a tone
*rescales what is already drawn* (desaturate toward luminance, then offset each
channel), so it cannot be one more layer on top. Instead every display object in
the viewport folds the viewport's tone into its own composite as the last step —
`Sprite` and `Plane` already baked their own tone into a scratch buffer, and the
`Tilemap` gets a pass over its composed ground and "above" canvases — and the
viewport re-composites its children when the value changes. That change check
runs from `#update` as well as on assignment, because the scripts mutate the Tone
in place (`viewport.tone.set(...)`); the re-composite is skipped unless the tone
actually moved, so a static map costs one comparison a frame.

This is the per-pixel tone pass the RPG2000 screen tint has also been waiting on
(`docs/TODO.md`) — `apply_tone_px` is now shared by all three composites, so the
RPG2000 side can adopt it rather than growing its own.

Not covered: `Window` (its contents are composed by a different path, and RGSS
puts windows in their own viewport, so a map tint does not tint the message
window anyway) and `Graphics.brightness`, which stays tracked-not-drawn — VX
fades through `@viewport3.color`, which does draw.

### 3. `Graphics.freeze` / `transition` / `snap_to_bitmap` — scene transitions dissolve ✅

`Scene_Base#perform_transition` freezes the frame and transitions into the next
scene (~5 uses each), and `Scene_Title` snapshots the screen with
`Graphics.snap_to_bitmap`.

**`snap_to_bitmap` is native now**: `lv_snapshot_take` re-renders the active
screen's object tree into an ARGB8888 buffer, which is the only capture that
works on every backend here — the SDL window, the terminal framebuffer and the
wasm canvas all buffer differently, and two of them render partially. The rows
come back in the byte order `Bitmap` already uses, so they copy straight across.

`freeze`/`transition` are built on it and are real: `freeze` keeps the snapshot,
and `transition` puts it on a full-screen sprite above everything (`z` at
`Graphics::TRANSITION_Z`) whose opacity is stepped to zero over `duration`
frames, so the next scene builds itself behind a fading still of the last one —
RGSS's default dissolve. The `filename`/`vague` form (dissolving *through* a
transition image) still runs as a plain fade of the same length and says so once.

Not covered: `play_movie` (there is no video decoder in the build).

This is also what made the effects testable. `mruby-rgss/test` has no display —
a `Viewport` cannot even be constructed there — so `Viewport#color`, `#tone` and
the transitions all landed without a test that could see a pixel. `RGSS.frame_mean`
(the mean R/G/B of the frame, sampled on an 8px grid) and `RGSS.effect_probe`
close that: `rpg_maker_clone --rgss_effect_probe` drives a grey screen, a red
`Viewport#color`, an additive-blue `Viewport#tone` and a freeze/transition round
trip on a real display and measures each one. It runs as the `render_probe`
ctest under xvfb, and it is the check that catches *the effect code runs and the
screen does not change* — the failure mode that hid the RPG2000 screen tint
(`docs/TODO.md`). Measured: `base=[128,128,128] color=[191,63,63]
tone=[128,128,255] cleared=[0,0,0] mid=[94,94,94] after=[0,0,0]`.

### 4. Window open/close is not animated, and `Window#tone` is not applied

`openness` is stored and the scripts' open/close loops terminate correctly, but
the native window is drawn full-size throughout, so a menu pops rather than
unrolls. `Window#tone` (the windowskin colour tint) is likewise stored only.

### 5. `Bitmap#blur` / `#radial_blur`

One use each (title background, animation effects). Cosmetic.

### 6. Reading graphics out of the encrypted archive ✅ (audio still to come)

Shared with the XP gap. `RPGVX::RGSSData` has resolved `Data/*` through
`Game.rgss2a`/`Game.rgss3a` for a while, but the native asset loaders only ever
opened files, so a packed release booted with no art at all — and `Cache.*` (a
script class) calls `Bitmap.new("Graphics/...")` for *every* asset.

**Graphics now come out of the archive.** The awkward part is not the decrypting
— `RPGXP::RGSSAD` already did that — but the plumbing: an asset is asked for by
name from deep inside a game's own scripts, with no handle to thread down. So
each boot shell registers its opened archive once as `RGSS.asset_archive`, and
`Bitmap#initialize` consults it after the loose-file search misses, trying the
same extension candidates (`.png`, `.jpg`, `.jpeg`, `.xyz`, `.bmp`). Loose files
still shadow packed ones, which is what RGSS itself does.

The decoding is unchanged, deliberately: `_init_file` and the new `_init_memory`
share one `bmp_decode_into`, so a packed asset goes through the same stb, XYZ and
tolerant-PNG path a loose one does — the fallbacks that a real RPG Maker project
needs are not something the archive path can quietly lack.

Verified end to end in the real binary by `scripts/rgssad_asset_check.bash`: the
XP test bed is packed twice, differing only in whether its title graphic is
inside `Game.rgssad`, and the engine must find it in the first and report the
miss in the second. The A/B is the point — a single run would pass just as well
if the archive were never consulted.

**Audio is still loose-file only.** `RGSS::Audio` plays through a C function
table (`include/rgss_audio.hxx`) whose entry points all take a path, so a packed
BGM needs that interface to grow memory variants (SDL_mixer reads from an
`SDL_RWops` happily enough). A packed game therefore boots and draws, but stays
silent.

## What this means for turning the host on

For VX / VX Ace the script host is not an alternative to a built-in flow — it is
the only route to a real game. A bundle now **runs**: it loads its database,
plays its music, reads input, drives frames, lays out its windows, draws its map,
tints, flashes and fades the screen, dissolves between scenes, and — packed or
loose — finds its graphics. What is left is narrow: **packed audio** (the second
half of item 6, a change to the audio backend's C interface), and the cosmetic
items 4 and 5.
