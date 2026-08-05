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

## Gaps ❌ (ordered by how much they block a playable VX game)

### 1. `Tilemap` is XP-shaped — the map cannot draw

`Spriteset_Map` builds the map with the RGSS2/RGSS3 tilemap:

```ruby
@tilemap = Tilemap.new(@viewport1)
@tilemap.map_data  = $game_map.data
@tilemap.bitmaps[i] = Cache.tileset(name)   # nine sheets: A1-A5, B-E
@tilemap.flags     = @tileset.flags         # the 8192-entry Table
```

`mruby-rgss`'s `Tilemap` is the XP one: `tileset=` (one sheet), `autotiles`
(seven) and `priorities`. VX/VX Ace need the **nine-sheet `bitmaps` array**, the
**`flags` table** (passage/priority/counter/terrain bits packed per tile id) and
the different **autotile geometry** (A1 water/A2 ground/A3 buildings/A4 walls
and the direct B–E pages). Native work in `mruby-rgss/src/lib.cxx`, and the
single biggest item here: without it a VX game boots but shows no map.

### 2. `Viewport#tone` / `#color` / `#flash` — no screen tint, flash or fade

VX/VX Ace do every screen effect through the viewport, not a sprite overlay:

```ruby
@viewport1.tone.set($game_map.screen.tone)              # tint
@viewport2.color.set($game_map.screen.flash_color)      # flash
@viewport3.color.set(0, 0, 0, 255 - $game_map.screen.brightness)  # fade
viewport.flash(timing.flash_color, timing.flash_duration)         # animations
```

Our `Viewport` has none of these (`ox`/`oy`/`rect`/`z`/`visible` only), so tint,
flash, fade-in/out and animation flashes are all inert. This is the same native
tone work the RPG2000 side is waiting on (`docs/TODO.md`), and doing it once on
`Viewport` would serve both. `Graphics.brightness` is tracked but not drawn for
exactly this reason.

### 3. `Graphics.freeze` / `transition` / `snap_to_bitmap` — no scene transitions

`Scene_Base#perform_transition` freezes the frame and transitions into the next
scene (~5 uses each), and `Scene_Title` snapshots the screen with
`Graphics.snap_to_bitmap`. `freeze`/`transition` are stubs that now consume the
right number of frames (so timing is right) but draw nothing; `snap_to_bitmap`
and `play_movie` do not exist. Needs a native frame grab.

### 4. Window open/close is not animated, and `Window#tone` is not applied

`openness` is stored and the scripts' open/close loops terminate correctly, but
the native window is drawn full-size throughout, so a menu pops rather than
unrolls. `Window#tone` (the windowskin colour tint) is likewise stored only.

### 5. `Bitmap#blur` / `#radial_blur`

One use each (title background, animation effects). Cosmetic.

### 6. Reading graphics/audio out of the encrypted archive

Shared with the XP gap: `RPGVX::RGSSData` resolves `Data/*` through
`Game.rgss2a`/`Game.rgss3a`, but the native `Bitmap`/`Audio` loaders only read
loose files, so a packed release boots with no graphics. `Cache.*` (a script
class) calls `Bitmap.new("Graphics/...")` for every asset, so this is what a
packed VX Ace game needs next after the tilemap.

## What this means for turning the host on

For VX / VX Ace the script host is not an alternative to a built-in flow — it is
the only route to a real game. With this round in place a bundle **runs**: it
loads its database, plays its music, reads input, drives frames and lays out its
windows. What it cannot yet do is **draw the map or any screen effect**, which
is items 1–3, all native `mruby-rgss` work.
