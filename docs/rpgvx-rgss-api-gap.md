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
  (~2), `stretch_blt`, `hue_change`, `clear`, `font`, `dispose`, `blur`,
  `radial_blur`. _Complete for the stock scripts._
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

**The A2 table tile's "leg"** — the 8px overhang that spills past a table
tile's own 32×32 box into the map row below it — is now drawn too. It looked
like the same gap XP's `priorities` had before [ADR 0022](adr/0022-rpgxp-tilemap-priority-layering.md)
(there described via MV corescript's `Tilemap#_drawTableEdge`, the JS name),
but MV's neighbour-examining mechanism is JS-only plumbing, not what real
VX/VX Ace draws — mkxp's `TileAtlasVX::readAutotileA2` (the actual VX/VX Ace
tile renderer) does it with no neighbour lookup at all: every table tile
grows its leg unconditionally, as a pure function of its own id. Cross-checked
against all 48 A2 shapes: a leg exists on a corner exactly when that corner
already trips the same-cell "counter row" substitution above (`qsy == 1` or
`5`), sourced from that corner's own unsubstituted position — so no new
lookup table was needed, only a second pass so the leg draws after the row
below's own tile (a plain per-tile pass would let that tile paint back over
it). Exposed as `Tilemap.vx_table_leg_quads` and pinned in `mruby-rgss/test`
the same way `vx_tile_quads` is.

**`flags` bit 0x10 ("higher tile") stays a flat "above the characters" layer,
and that is correct, not a placeholder.** This looked like the same
approximation ADR 0022 describes for XP's `priorities` — a flat layer instead
of per-row interleaving with characters — but it is not one: mkxp's
`TilemapVX` (the reference used above) puts its own "above" layer at a fixed
`z = 200` (`TilemapVXPrivate::AboveLayer`), never per-row. RMXP's per-row
`screen_z` is specific to XP's own `Game_Character#screen_z` formula (see the
ADR); VX/VX Ace's own engine does not do that for `flags` 0x10, so widening
ADR 0022 to VX would have made this *less* faithful, not more. No follow-up
wanted here.

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
RGSS's default dissolve. The `filename`/`vague` form dissolves *through* the
transition graphic instead: its brightness says when each pixel gives way — dark
first, light last — and `vague` how soft the boundary between the two is, which
is what makes a battle transition the shape its author drew. The shader-based
players evaluate `clamp((t - prog) / vague, 0, 1)` on the GPU; there is none
here, so `Bitmap#_transition_alpha` rewrites the snapshot's alpha channel once
per frame. A graphic that will not load falls back to the plain fade and says so
once.

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

The transition graphic is measured there too, and it needs a different kind of
assertion: a dissolve that ignored its map would still change the frame, just
uniformly. So the probe half-dissolves a solid red still through a left-to-right
gradient and means the quarter-screen at each edge separately — the dark side
has to be gone while the light side is still standing. A flat fade moves both
together, which is exactly the bug a whole-frame mean cannot see.

### 4. Window open/close animates, and `Window#tone` is applied ✅

`openness` used to be stored while the window drew full-size throughout, so a
menu popped rather than unrolled; `Window#tone` was stored only.

**`openness` is drawn now.** The window unrolls from its horizontal centre line:
the frame is composited at `height * openness / 255` and the object shifted down
by half of what it lost, so it grows out of the middle the way RGSS does it. The
9-slice's corner height is clamped to half the drawn height, so a part-open
window keeps a frame instead of laying its top and bottom borders over each
other. Contents, cursor and pause arrow are hidden until it is fully open —
only the frame animates. `Window_Base#open` steps `openness` by 48 a frame, so
this is the whole animation.

**`Window#tone` is drawn too**, over the *background* only: it is applied to the
canvas right after the background tile is laid down and before the frame and
contents go on top, which confines it without a second buffer. Unlike
`Viewport#tone` it is not folded in by children — a window composites itself, so
it tones its own pixels — but the per-pixel maths is the same shared
`apply_tone_px`, so the three tone paths cannot drift. `Window#update`
re-checks it, because the scripts mutate the Tone in place
(`window.tone.set(...)`); one comparison a frame when it has not moved.

Both are native, and deliberately *not* redefined in mrblib: that loads after the
C init, so a Ruby accessor there would shadow the native one and quietly go back
to storing a value that draws nothing.

Measured by `RGSS.window_probe` in the `render_probe` ctest — a 320×240
solid-blue window on a 544×416 screen, so the frame's mean blue is the fraction
of the screen it covers: `drawn=[0,0,86] half=[0,0,43] closed=[0,0,0]
toned=[86,0,86]`. 43 is half of 86, and 86 is 255 × 320×240 / (544×416). Both
halves were confirmed non-vacuous by breaking them in turn.

### 5. `Bitmap#blur` / `#radial_blur`

### 5. `Bitmap#blur` / `#radial_blur` ✅

One use each (title background, animation effects), both native now.

`blur` is a 3×3 box blur run over a snapshot of the bitmap, so every output
pixel reads the *original* neighbourhood — blurring in place would feed
already-blurred pixels back in and smear along the scan order instead of evenly.
Edge pixels average only the neighbours that exist, so the border is not dragged
toward transparent. RGSS's own blur takes no parameters, so there is nothing to
tune.

`radial_blur(angle, division)` averages `division` copies of the image spread
evenly over `angle` degrees and centred on the original, so the result is
symmetric rather than smeared to one side. Samples that rotate off the bitmap
contribute nothing, which keeps the corners from pulling in transparent pixels.
`division < 2` or `angle == 0` is the identity.

Both average the channels **premultiplied by alpha**: a transparent neighbour
then contributes weight but no colour, instead of dragging colour out of an
opaque pixel.

Unlike the rest of this document these are pure pixel work, so they are pinned
properly in `mruby-rgss/test` rather than measured on a display — including the
exact seam values a box blur produces (170 and 85 either side of a white/black
edge) and the mirror symmetry of the swept arc, which is what actually pins the
centre of rotation.

### 6. Reading graphics and audio out of the encrypted archive ✅

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

**Audio comes out of the archive too.** `RGSS::Audio` plays through a C function
table (`include/rgss_audio.hxx`) whose entry points all took a path, so each has
grown a `*_play_mem` twin taking the encoded bytes; the SDL backend feeds them to
`Mix_LoadMUS_RW`/`Mix_LoadWAV_RW` through an `SDL_RWops`. The Ruby side mirrors
`Bitmap`: after the disk search misses, the four kinds' archive folders are
crossed with the same extensions, so a bare `"Theme1"` finds
`Audio/BGM/Theme1.ogg`.

The subtlety is lifetime. `Mix_LoadMUS_RW` *streams* from the RWops, so the bytes
must outlive the music — and RGSS resumes the BGM after a music effect ends,
which with an archived track means replaying from bytes that have to still be
there. Both buffers are owned by the backend and released only where the stream
they feed is freed.

Verified by the `audio_probe` ctest, which plays the same sound from a loose file
and then out of an archive under `SDL_AUDIODRIVER=dummy` (SDL's dummy driver
decodes and mixes with no sound card) and requires both to advance
`Audio.bgm_pos` — with a *stop* between them that must read 0. That middle step
is what earns the other two: without it the packed arm passed against an empty
archive, because `bgm_pos` was reporting the loose track's position. Halting
music does not free the stream, and `Mix_GetMusicPosition` kept answering for a
stopped one; a game saving `bgm_pos` to resume a track later would have recorded
a position for music that was not playing. Fixed while building the probe.

### 7. The RGSS3 `BaseItem` superclass chain, and what a real game's own community scripts need ✅ (mostly)

Everything above was measured against the synthetic test bed
(`scripts/rpgvx_testbed_check.rb`) and small hand-authored projects. Neither
ever *reopens* a stock `RPG::` class the way a real VX Ace project does, so
this whole class of gap was invisible until a real, large freeware VX Ace
release (a ~60-hour RPG, 468 maps, 930 skills, 610 enemies) was booted through
the script host.

**`TypeError: superclass mismatch for RPG::Actor` ended every real VX Ace
game's boot.** The editor exposes `BaseItem`/`UsableItem`/`EquipItem`/
`Actor`/`Class`/`Item`/`Skill`/`Weapon`/`Armor`/`State`/`Enemy` as ordinary,
editable script sections (its "RPG" folder) — unlike XP, which compiles the
equivalent classes into the DLL. Every one of these sections' first line
reasserts its stock superclass, e.g. `class RPG::Actor < RPG::BaseItem`, even
when a game's own customisation only touches the body below it. `mruby-rpgxp`
(loaded first, shared by all three RGSS makers) declared these classes flat —
no superclass — because it predates VX Ace and a class's superclass cannot
change once set. `mruby-rpgvx/mrblib/rgss2_data.rb` worked around that by
composing the RGSS3 fields through `*Fields` modules instead of real
inheritance, which was invisible to every check *until a real game's own
section reasserted the superclass it never got*. Fixed by giving
`mruby-rpgxp/mrblib/rgss_data.rb` the real chain from each class's first
declaration (see the comment on `class BaseItem` there) — this is very likely
the single biggest reason a real VX Ace release could not boot at all.

**The 64 MB LVGL heap** (which backs mruby's whole VM heap on desktop, not
just graphics) was too small for this game's database alone — `NoMemoryError`
during `Data/*.rvdata2` loading, before a single scene ran. Raised to 256 MB
for desktop (PSP/Wio keep their own separate, already-tuned pools).

**Community utility scripts assume more Ruby/Windows surface than this build
ships**, found by continuing past the superclass fix into the game's own
bundled scripts: `Win32API` (RGSS's DLL-call class — many optional-feature
utility scripts, e.g. the widely bundled CACAO 画像保存 screenshot saver,
bind several calls unconditionally at load time) and `String#encode` (this
mruby build has no transcoding tables) are now filled in as inert
warn-once-and-degrade shims — matching the existing `Errno` fill-in's
philosophy of "must exist, does not have to work" for something outside this
engine's reach. `Module#private_method_defined?`/`#protected_method_defined?`/
`#public_method_defined?` are filled in for real (mruby-metaprog already
tracks the data `private_instance_methods` needs) rather than stubbed.

**Still open: `module_function` with no arguments is a documented no-op in
this mruby version.** CRuby's "declaration mode" `module_function` — call it
bare, and every subsequent `def` in that scope becomes both a private
instance method *and* a public singleton method — needs compiler-level
"default definee" tracking that upstream mruby's own source marks
unimplemented (`mrb_mod_module_function` in `3rd/mruby/src/class.c`: `if
(argc == 0) { /* set MODFUNC SCOPE if implemented */ return mod; }`). The
explicit-argument form (`module_function :name`, converting an
already-defined method) works correctly and is what most RGSS scripts use for
a single utility method, but a module built entirely under a bare
`module_function` declaration — e.g. the same real game's bundled error-log
utility, `TKG::ErrorLog`, whose `save` is only ever reachable as
`TKG::ErrorLog.save(...)` — silently defines no singleton methods at all,
raising `NoMethodError` the first time the game tries to call one. This is an
upstream mruby limitation (reproduced and confirmed in isolation, not
specific to this project's config or build), not something to patch in the
vendored submodule for one script's sake; real content that needs it working
would want this revisited.

## What this means for turning the host on

For VX / VX Ace the script host is not an alternative to a built-in flow — it is
the only route to a real game, which is why it now runs **by default** here as on
the XP side ([ADR 0029](adr/0029-rgss-script-host-by-default.md); the pending
notice is what a project without scripts, or a boot with `RGSS_SCRIPT_HOST=0`,
gets instead). A bundle now **runs**: it loads its database,
plays its music, reads input, drives frames, lays out its windows, draws its map,
tints, flashes and fades the screen, dissolves between scenes, unrolls and tints
its windows, and — packed or loose — finds its graphics and its music, and
reopens its own stock `RPG::` script sections without a superclass mismatch.
Tilemap item 1's remaining polish (the flat "above characters" layer) is the
only item left in the six sections above; item 7's `module_function` gap is
the newest and, per a real release, potentially the most consequential.
