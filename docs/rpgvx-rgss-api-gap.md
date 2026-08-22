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
window anyway).

**`Graphics.brightness`/`fadeout`/`fadein` are drawn too, now** — a real gap
found and fixed independently of the VX viewport-color work above, on the XP
side: VX/VX Ace fade through `@viewport3.color` (drawn, as above), but RMXP's
own stock scripts (`Scene_Gameover`, `Scene_End`, several post-battle screens)
call plain `Graphics.fadeout`/`fadein` directly, and `Graphics.brightness=`
(`mruby-rgss/mrblib/lib.rb`) only ever tracked the value — a real XP game
would previously show no visual fade at all in those spots. Fixed with the
same overlay technique `Graphics.transition` already uses for its own
full-screen dissolve (proven, native, tested): a full-screen black `Sprite`
at `BRIGHTNESS_Z` (just under `TRANSITION_Z`), created once and kept alive,
whose opacity is `255 - brightness`. `fadeout`/`fadein` themselves needed a
second, related fix once brightness was real: they ran all `duration` frames
first and only set the end value afterward, which had been an invisible bug
(brightness was never drawn either way) that would have become a visible
"nothing happens, then instant cut to black" the moment the overlay existed —
now each fades one step per frame. Verified against the real
`--rgss_effect_probe` CTest, through a live display: `Graphics.brightness = 0`
darkens `frame_mean` to `[0, 0, 0]` from a `[128, 128, 128]` base, and
`Graphics.brightness = 255` restores it exactly.

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

**Fixed: bare `module_function` was a documented no-op in this mruby
version.** CRuby's "declaration mode" `module_function` — call it bare, and
every subsequent `def` in that scope becomes both a private instance method
*and* a public singleton method — needs compiler-level "default definee"
tracking that upstream mruby's own source marks unimplemented
(`mrb_mod_module_function` in `3rd/mruby/src/class.c`: `if (argc == 0) { /*
set MODFUNC SCOPE if implemented */ return mod; }`). The explicit-argument
form (`module_function :name`, converting an already-defined method) works
correctly and is what most RGSS scripts use for a single utility method, but
a module built entirely under a bare `module_function` declaration — e.g. the
same real game's bundled error-log utility, `TKG::ErrorLog`, whose `save` is
only ever reachable as `TKG::ErrorLog.save(...)` — silently defined no
singleton methods at all, raising `NoMethodError` the first time the game
tried to call one.

Reimplemented without touching the vendored mruby core: `method_added` fires
reliably for every `def` (the VM only skips calling it while it is still the
built-in no-op — `mrb_method_added` in class.c — so overriding it once here
costs nothing for classes that never trigger it), and the explicit-argument
form already promotes an existing method correctly. Bare `module_function`
now just flips a per-module flag; `method_added` — called after the method is
already registered — hands the new name to the explicit-argument path to
promote it, one step behind CRuby's compile-time version but the same
result. Bare `private`/`public` (which this mruby version *does* implement
correctly, via real per-scope visibility tracking — `find_visibility_scope`
in class.c) end the declaration, so a script returning to ordinary instance
methods afterward is not stuck being module_function forever. What this does
not reproduce: CRuby's version is true lexical-scope state, reset on leaving
the enclosing `module`/`class` body; this is a per-module flag that persists
until explicitly turned off, so a script that reopens the *same* module later
without an intervening bare `private` would see those methods wrongly
promoted too — narrow in practice, since RGSS scripts overwrite this as one
contiguous run.

**Fixed: `Time#strftime` did not exist.** mruby-time uses the C library's
`strftime()` internally for `Time#to_s`, but never bound a Ruby-level method
taking a format string — and formatting a timestamp for a log line or a save
filename is completely ordinary (the same error-log utility:
`"Log/error_log" + Time.now.strftime("%Y%m%d%H%M%S") + ".txt"`). Implemented
in pure Ruby over the component accessors `Time` already exposes
(`year`/`mon`/`day`/`hour`/`min`/`sec`/`wday`/`yday`/`usec`/`utc_offset`),
covering the common date/time directive set real scripts use — not the full
CRuby spec (no `%V`/`%U`/`%W` week-of-year, no locale forms, no field-width
modifiers). An unrecognised directive passes through literally.

**Fixed: `Dir.glob` did not exist.** `Dir` is present in this build at all
only incidentally — `build_config.rb`'s `enable_test` pulls the vendored
`mruby-dir` gem in as a host-build test dependency, and the same shared
`libmruby.a` backs the actual game binary too — but `mruby-dir` itself
(`3rd/mruby/mrbgems/mruby-dir`) never implements `.glob` at any layer: its
mrblib only supplies `#each`, `#each_child`, `.foreach`, `.open` and
`.chdir`; its C HAL only wraps opendir/readdir/mkdir/rmdir. `Dir.glob` is not
an obscure feature real scripts reach for on purpose: the stock RPG Maker VX
Ace `DataManager` checks `!Dir.glob('Save0*.rvdata2').empty?` to decide
whether the title screen offers "Continue", `Game_System` globs a shared
options file the same way, and a released game routinely adds a
`Dir.glob('Game.rgss3a').empty?` check to tell a packed release apart from
an unpacked project — none of that is optional or RTP-shaped, so
`NoMethodError` here failed the whole script host before a single frame
drew. Implemented in pure Ruby (`mruby-rpgxp/mrblib/rgss_library.rb`) over
`Dir.entries` (which the HAL does supply) and a glob → `Regexp` translator
covering literal names, `*`, `?` and `[...]` character classes — not the
full glob spec (no `**`, brace expansion or flags) — walking a pattern one
`/`-separated path component at a time so a prefix like
`Data/Map[0-9]*[0-9].rvdata2` only lists `Data/`'s own entries.

**Fixed: `Color.new` / `Tone.new` wrongly required arguments.** Not a script
gap at all — this is a bug in `mruby-rgss`'s own native binding
(`mruby-rgss/src/lib.cxx`), the class library this engine supplies natively
rather than through mrblib. Real RGSS3's *own* stock, unmodified
`Game_Screen#clear_tone` / `#clear_flash` — present in every VX Ace
project's default `Scripts.rvdata2`, not a community add-on — call
`Tone.new` and `Color.new` with **zero** arguments, relying on every
component defaulting to 0 (opaque black / no tone shift). `color_init` and
`tone_init` read their arguments with `mrb_get_args(M, "fff|f", …)` — 3
required, 1 optional — so `Color.new`/`Tone.new` raised
`ArgumentError: wrong number of arguments (given 0, expected 3..4)` on
every VX Ace game that constructs a `Game_Screen`, which is to say every VX
Ace game the script host boots far enough to reach it. The C++ locals
already had the right defaults (`r = g = b = 0`) sitting dead behind the
argument-count check; changed the format to `"|ffff"` (all four optional)
and the `MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1)` declarations to
`MRB_ARGS_OPT(4)` for both `initialize`s. `Color#set` / `Tone#set` are
untouched — real scripts always call those with explicit arguments.

**Changed: the desktop LVGL heap grows again, 256 MB → 512 MB.** The first
bump (`changelog.d/desktop-lvgl-heap-256mb.changed.md`) was measured against
this same real VX Ace release's *database* load alone. Past the two fixes
above, the script host now reaches actual scene construction — building the
title screen's own windows, sprites and bitmaps — which is a second, larger
memory consumer 256 MB did not cover: the game aborted with
`NoMemoryError` mid-boot even with a fully loaded database. 512 MB cleared
it. Desktop-only, same as before (`include/lv_conf.h`; the PSP and Wio
builds keep their own separately-tuned pools).

**Fixed: mruby's VM had no `$!` ("currently handled exception") at all.**
`rescue => e` binds the exception to the clause's own local variable, but
the special global CRuby code routinely reads instead — `$!`, what
`Exception#message`/`#backtrace` resolve through implicitly when a method's
default argument or a nested `raise` (no arguments — CRuby re-raises `$!`)
needs "whatever is currently being rescued" without it being threaded
through as an explicit parameter — was simply never written anywhere
accessible from Ruby. Traced to the VM opcode itself: `OP_EXCEPT` in
`3rd/mruby/src/vm.c` copied the caught exception into a bytecode *register*
(a local stack slot) and immediately cleared `mrb->exc` to `NULL`, with no
call to `mrb_gv_set` or any other globally-visible store. Confirmed with an
isolated reproduction — even a bare `rescue => e; $! ...` inside the *same*
method read `nil`, so this was not specific to crossing a call boundary. It
is why the same error-log utility's `save(filename = nil, exception = $!)`
— called as `TKG::ErrorLog.save()` from directly inside `rescue;
TKG::ErrorLog.save(); raise; end` — received `exception = nil` and crashed
on `exception.message`.

Fixed by `patches/mruby-dollar-bang-scoped.patch` (that patch's own preamble
has the full trail, including two earlier approaches that were tried and
rejected: codegen-level save/restore around rescue bodies, which regressed
the compiler's register allocation, and a sticky global that leaked into
unrelated code and broke three core mrbtest cases). The fix that stuck adds
`errinfo`/`errinfo_ci_depth` to `mrb_state`: `OP_EXCEPT` sets `errinfo` to
the caught exception and records the call-frame depth that owns it — by the
time `OP_EXCEPT` runs, mruby's own exception search has already popped
every frame between the raise site and the frame whose `rescue` matches, so
that depth is simply the current one, no deferred capture needed — and
`cipop` (mruby's existing frame-pop) clears `errinfo` once execution returns
to a shallower depth, so it is visible for the whole rescue body (including
calls the body itself makes) but never leaks past the owning frame's
return. `mrb_gv_get`/`mrb_gv_set` special-case the `"$!"` symbol to read and
write `errinfo` directly, so both a Ruby-level `$!` and a bare `raise`
(kernel.c) see the same value uniformly. Companion fix in the same patch: a
bare `raise` — CRuby's documented way to re-raise `$!` — always raised a
fresh, empty `RuntimeError` instead, since `mrb_f_raise` had nothing to fall
back to; with `errinfo` now tracked, its zero-argument case re-raises it
directly, no wrapping of every `raise` call needed (the earlier, rejected
idea for fixing this half on its own). One known gap versus real Ruby: this
scopes `$!` to the whole call frame, not to each individual `rescue`
clause, so two `rescue` clauses in the same frame with no intervening call
share one slot — not believed to matter for any known real game script.
Verified against a real repro of this exact pattern (`$!` readable and
correct inside the rescue and from a callee it invokes, `nil` again once the
frame returns; a bare `raise` re-raising the original class and message)
and the full mruby test suite (zero regressions from a core VM change).

That `SceneManager.run` rescue wraps the game's *entire* run loop, so this is
not a one-time cosmetic loss: every fatal exception this game hits, of any
origin, is masked behind the identical `NoMethodError: undefined method
'message' for NilClass` crash in the error-log utility, until whatever real
exception triggered it is fixed and the *next* one takes its place. Diagnosing
each of the fixes above (and the five below) required a temporary,
never-committed `fprintf` at the `OP_EXCEPT` opcode itself (in the local
`3rd/mruby` submodule checkout, reverted before every commit) to read the
masked exception directly off the VM — eight separate real bugs found this
way, one at a time, each hidden behind the identical crash until fixed:

- **Fixed: `Window#contents` started `nil` instead of a real `Bitmap`.**
  Another native `mruby-rgss` binding bug (`window_init` in
  `mruby-rgss/src/lib.cxx`), not a script gap. Real RGSS3's own stock,
  unmodified `Window_Base#create_contents` — called from `#initialize`, so
  every single `Window` a game ever constructs runs it once immediately —
  starts with a bare `contents.dispose`, on the assumption a freshly built
  `Window` already owns a (trivial) disposable `Bitmap`. This engine's
  `window_init` set `@contents` to Ruby `nil` instead, so the very first
  `Window_Base`-derived window any VX Ace game ever constructs —
  `Scene_Title`'s own `Window_TitleCommand` — raised `NoMethodError:
  undefined method 'dispose' for NilClass` before a single frame of the
  title screen drew. Fixed by having `window_init` construct a real 1×1
  `RGSS::Bitmap` (the same `DataType<Bitmap>::make` helper
  `window_ensure_canvas` already uses a few lines below it) and store that
  instead of `mrb_nil_value()`.

- **Fixed: `Audio.bgm_play` rejected RGSS3's 4th (`pos`) argument.** A real
  gap, not a bug — `mruby-rgss/mrblib/lib.rb`'s `bgm_play(filename, volume =
  100, pitch = 100)` never grew the `pos` parameter RGSS3 added over
  XP/VX's 3-argument form (VX Ace resumes a BGM's playback position — a
  save's `RPG::BGM#replay`, or a bare `Audio.bgm_play(f, v, p, pos)` a
  volume-control add-on script called directly — see the real
  `RPG::BGM#play` reopened by this same release's add-on). Every VX Ace
  game whose title screen calls `Audio.bgm_play` with 4 arguments raised
  `ArgumentError` right there. First fixed by accepting `pos = 0` and
  warning once that seeking was unsupported when it was non-zero — no
  backend seeked a mid-stream start position at the time.

  **Later, seeking itself was implemented**, once the fix above's own
  warning made it an obvious next target: `pos` now threads through to
  `Mix_SetMusicPosition` (`src/sdl_audio.cxx`'s `start_music`), on both the
  loose-file and packed-archive paths (a released game's whole `Audio/`
  tree is packed, so the archive path — `_bgm_play_mem`, not `_bgm_play` —
  is what an actual game's resume reaches). `pos` is milliseconds, the same
  unit `Audio.bgm_pos` already returns, so `Audio.bgm_play(f, v, p,
  Audio.bgm_pos)` round-trips exactly through this engine's own two halves;
  a real VX Ace script's own hardcoded literal may use a different native
  unit (secondary sources disagree on RGSS3's own — one empirical report
  put "a couple of seconds" at a raw value in the millions, ruling out
  simple seconds-as-float or milliseconds-as-int, and none of the
  authoritative sources could be reached to settle it), so this is a
  best-effort match, not a confirmed one. A decoder that cannot seek (or
  fails to) still plays from the track's own beginning rather than not
  playing at all. Verified against the real `--rgss_audio_probe` CTest,
  through SDL_mixer against a real (dummy-driver) audio device: seeking a
  2-second synthetic WAV to 1000ms reads back `bgm_pos` near 1000 on both
  the loose and packed paths (`seek_got`/`packed_seek_got` in its
  `[RGSS-AUDIO]` log line) — not just accepted without raising, the
  resume is real.

- **Fixed: BGM never resumed after a Music Effect, and `RPG::BGM#replay`
  never passed its stored `pos` through.** The two related gaps the fix
  above left open. `Audio.me_play`/`me_play_mem` (`src/sdl_audio.cxx`) now
  capture the BGM's own position (`bgm_pos()`) the instant an ME
  interrupts it — only on the first ME of a run, not one that replaces
  another already playing, which would read 0 (`bgm_pos` reports 0 while
  an ME is active) and lose the real resume point — and `me_stop`'s
  `replay_bgm()` seeks there instead of always restarting the track,
  matching real RGSS3 (an ME plays once over the map BGM, which picks back
  up where it left off). `RPG::BGM#replay`
  (`mruby-rpgvx/mrblib/rgss2_runtime.rb`) is now overridden on `BGM` itself
  (the other three `AudioPlayback` channels keep the shared "just `#play`
  again" default, since only BGM's backend can resume a position — `BGS`'s
  own `pos` field exists for save-format fidelity, but its sample-channel
  backend never reports one to resume from; `ME`/`SE` have no `pos` field
  at all) to call `Audio.bgm_play` with its own stored `volume`/`pitch`/
  `pos` — what a save loaded mid-track relies on. Verified against the
  real `--rgss_audio_probe` CTest: playing a BGM, letting it advance past
  500ms, interrupting it with an ME and stopping the ME reads `bgm_pos`
  back near where it was (`pre_me`/`me_resumed` in its `[RGSS-AUDIO]` log
  line), not reset to 0.

- **Fixed: `RPG::CommonEvent` had no `#autorun?` / `#parallel?`.** A real
  data-layer gap in `mruby-rpgvx/mrblib/rgss2_data.rb`: `CommonEvent` only
  ever exposed the raw `trigger` integer (0 none, 1 autorun, 2 parallel).
  Real RGSS3's own stock, unmodified `Game_Map#setup_autorun_common_event`
  and `#parallel_common_events` call the predicates directly rather than
  comparing `trigger` themselves, so `DataManager.setup_new_game` →
  `Game_Map#setup` → `#setup_events` raised `NoMethodError: undefined
  method 'parallel?' for RPG::CommonEvent` on every VX Ace game that starts
  a new game — every VX Ace game reaches this the moment a player presses
  New Game, VX Ace's own "Parallel Process" trigger having no XP/VX
  equivalent means this was invisible on every project this host had
  reached new-game setup on before. XP's own stock scripts, confirmed
  against both XP test beds, never call either predicate — the fix is
  scoped to `mruby-rpgvx` only.

- **Fixed: `Bitmap#draw_text` raised `TypeError` on a non-`String` text
  argument.** A native `mruby-rgss` binding bug (`bmp_draw_text` in
  `mruby-rgss/src/lib.cxx`). Real RGSS3 accepts *any* object as the text
  argument — games routinely `draw_text` an `Integer` directly, exactly as
  this same release's own stock `Window_Gold#refresh` →
  `#draw_currency_value` does (`draw_text(x, y, w, h, $game_party.gold,
  2)`), relying on the same implicit `#to_s` real Ruby's `String()` gives
  it. `mrb_get_args`' `"s"` format demands an actual `String`, so every VX
  Ace game whose `Scene_Map` builds its `Window_Message` (which builds a
  `Window_Gold` among its child windows) raised `TypeError: Integer cannot
  be converted to String` right there. Fixed by parsing the text argument
  as a generic object (`"o"`) instead of `"s"`, coercing it via
  `mrb_obj_as_string` only after that single parse completes if it is not
  already a `String`. **Not** by grabbing a raw `argv` pointer via
  `mrb_get_args(M, "*", …)`, coercing in place, then calling
  `mrb_get_args` a *second* time with the strict format against that same
  pointer — the first attempt at this fix did exactly that, and segfaulted:
  `mrb_obj_as_string` can run arbitrary Ruby (`#to_s`) and potentially grow
  the VM's value stack, which would leave the first `argv` pointer
  dangling, and the second `mrb_get_args` call read through it. Caught by
  `scripts/rpgxp_boot_check.bash`, which every windowed screen a real
  project draws exercises directly.

- **Fixed: `RPG::EventCommand` had no `#initialize` at all.** A real
  data-layer gap in both `mruby-rpgvx/mrblib/rgss2_data.rb` and
  `mruby-rpgxp/mrblib/rgss_data.rb`: `EventCommand` only ever carried a
  bare `attr_accessor` for `code`/`indent`/`parameters`, falling back to
  `Object`'s own zero-argument default constructor. Real RGSS documents
  `EventCommand.new(code = 0, indent = 0, parameters = [])` for scripts
  that synthesize new event commands directly — this same release's own
  error-log utility does exactly that
  (`RPG::EventCommand.new(355, 0, ["@commonevent_id = #{@id}"])`, stamping
  a synthetic "script call" onto the front of every common event's own
  `#list` so a crash can name which one was running), which raised
  `ArgumentError: wrong number of arguments (given 3, expected 0)` the
  first time any VX Ace game calls a common event. Fixed by adding the real
  constructor to both makers' `EventCommand`; Marshal deserialization of
  existing `Data/*.rvdata(2)` — which allocates and restores instance
  variables directly, never calling `#initialize` — is unaffected, confirmed
  by `scripts/rpgxp_testbed_check.rb`/`rpgvx_testbed_check.rb` re-parsing
  real event-command data (15,797 XP event commands) cleanly afterward.

- **Fixed: `Sprite` had no `#width` / `#height`.** A real gap in
  `mruby-rgss/mrblib/lib.rb`: the native `Sprite` class binding
  (`src/lib.cxx`) never exposed them, and neither did the mrblib
  reopening that already fills in `x`/`y`/`z`/`opacity`/`ox`/`oy` and the
  rest of what the native `#initialize` never sets. RGSS3 (VX Ace) added
  `Sprite#width`/`#height` over XP/VX's `Sprite` — read-only, mirroring
  the sprite's own `bitmap` dimensions, `0` with none set — so scripts can
  position something relative to a sprite without tracking its bitmap
  size separately. This same release's own bundled speech-bubble add-on
  (`吹きだしウィンドウ`, "bubble window") does exactly that, centring its
  tail sprite under a message window (`self.y - @tail.height / 2` in
  `get_tale_pos_normal_updown`, `@tail` a real `Sprite.new`), which raised
  `NoMethodError: undefined method 'height' for RGSS::Sprite` the first
  time the game showed a message. `Window` and `Graphics` both already
  had `#width`/`#height` — only `Sprite` was missing them. Fixed by
  adding both, delegating to `bitmap.width`/`bitmap.height` when a bitmap
  is set.

With all nine gaps above closed, the same real VX Ace release now reaches
past `Scene_Title`'s title-command window, its title music,
`DataManager.setup_new_game`'s common-event setup, its first common event
call, and the bundled speech-bubble add-on's own text layout — into
further gameplay. What comes next needed two corrections to the diagnostic
method itself before it could even be investigated properly:

**Not a bug: `RGSS::Timeout` is this engine's own `--timeout_ms` safety
valve** (`gfx_update` in `mruby-rgss/src/lib.cxx`), not a script or engine
gap. A short headless-run budget (the 30 s the boot checks default to)
reliably fires it well before the game reaches anything new, because
`--rgss_host_new_game` deliberately taps the title screen's confirm key
only once per *real* second (so a headless run looks like a human, not a
key-repeat exploit), and this release's own opening has enough dialogue
that clearing it costs most of a short budget on its own. Raising
`--timeout_ms` past a minute or so reaches real further content reliably;
below that, a `RGSS::Timeout` in a probe run means "give it more wall
clock," not "something broke."

**Found and fixed: a real VX Ace game's own bundled `マップフォグ` ("Map
Fog") add-on used to never finish setting up, so a later event's inline
"Script" command that depends on it failed.** The add-on's own
`module Interface; ::MapFog = self` — an explicit *top-level* constant
assignment, written from inside a nested module — silently landed on the
lexically enclosing module instead of at the top level, no exception
raised. (An earlier pass at this same failure suspected the add-on's
preceding `module BMSP; @@includes ||= {}` — a fresh, never-before-set
class variable — but that line is handled correctly: mruby's compiler
already wraps `||=`/`&&=` on a class variable or constant in a
compiler-generated rescue that turns the `NameError` into `false` rather
than letting it escape, mirroring real Ruby exactly. That was a red
herring; the actual bug has nothing to do with class variables, and a
name-collision theory formed while re-investigating — that the nested
module and the top-level target sharing a name (`MapFog`) mattered —
was disproven the same way, by renaming the nested module and watching
the failure persist identically.)

The real bug is in `gen_colon3_assign`
(`3rd/mruby/mrbgems/mruby-compiler/core/codegen.c`), the codegen for
`::Const = value` (`NODE_COLON3` in assignment position): it pushes
`Object` via `OP_OCLASS` — exactly mirroring `gen_colon2_assign`'s
handling of the explicit-base form `Foo::Const = value`, which correctly
finishes with `OP_SETMCNST` (the opcode that reads that pushed value as
the constant's owner) — but then emits `OP_SETCONST` instead.
`OP_SETCONST`'s own VM handler (`3rd/mruby/src/vm.c`) never reads that
pushed value at all; it always targets
`MRB_PROC_TARGET_CLASS(ci->proc)`, the current lexically enclosing
class/module — exactly right for a *bare* `Const = value`, but wrong for
`::Const = value`, whose entire point is to bypass the enclosing scope.
The *read* path already gets this right — `codegen_colon3` pairs the same
`OP_OCLASS` push with `OP_GETMCNST`, not `OP_GETCONST` — so this reads as
a copy/paste slip in the assignment counterpart that was never given its
own read/write symmetry check. Confirmed against real CRuby: `ruby -e
'module Foo; ::Bar = 42; end; p Object.const_defined?(:Bar)'` prints
`true`; mruby's did not.

Since this submodule tracks upstream `mruby/mruby` directly (no fork
this project controls to carry the fix on), the fix ships as
`patches/mruby-colon3-assign-setmcnst.patch` (one line:
`gen_colon3_assign` now finishes with `OP_SETMCNST`), applied
idempotently at build time by `scripts/apply_mruby_patch.bash` — the
same `patches/` + apply-script convention already used for the PSP
toolchain's own patch. Verified against: a minimal synthetic repro
matching the real semantics, the full mruby test suite (zero
regressions from a compiler-level change), and the real, unmodified
516-line script — `Object.const_defined?(:MapFog)` now returns `true`
after it runs.

mruby's bare `raise` (no arguments) had the same root cause from the other
side: real Ruby re-raises `$!`, but mruby's `mrb_f_raise` had no `$!` to
fall back to, so a bare `raise` always raised a fresh, empty `RuntimeError`
instead of re-raising what was actually caught. An earlier pass at this
considered both fixable *only* by hooking `Kernel#raise` itself — wrapping
every `raise` call in the whole engine in an extra begin/rescue to capture
and stash the exception before it propagates, on every platform this build
targets, PSP included, where call-stack depth is already the tightest
constraint — and left both alone rather than take on that blast radius for
one utility script's log fidelity. `$!` itself turned out to have a much
smaller, VM-internal fix (see above); once that fix's `mrb->errinfo` field
existed, the wrapping was never needed for `raise` either — `mrb_f_raise`'s
zero-argument case now just re-raises `mrb->errinfo` directly when one is
in scope. Both are fixed by `patches/mruby-dollar-bang-scoped.patch`.

**Found and fixed: with `$!` finally working, the same real VX Ace release's
crash-reporter add-on stopped masking exceptions -- and the game hung for
minutes instead, on something that had nothing to do with `$!` at all.**
Booting past the `マップフォグ` fix with `$!` in place produced total
silence: no scene transition, no exception, no `[RPGXP-HOST-SCENE]` marker,
just CPU pinned at 100% for as long as the run was given (tested past four
minutes). Diagnosed by attaching `gdb` to the running headless process mid-hang
(a real C++ backtrace, not the temporary `OP_EXCEPT` `fprintf` probe used
above -- this hang was native, not a masked Ruby exception) and sampling it
repeatedly: every sample landed inside `Tilemap#ox=`/`#oy=` or
`Plane#ox=`/`#oy=` (`mruby-rgss/src/lib.cxx`), specifically inside their own
`tilemap_refresh`/`plane_retile` — a full CPU-side re-composite of the visible
tile grid or fog layer into an offscreen canvas. A temporary call counter
confirmed why: hundreds of consecutive calls to the exact same already-stored
`ox`/`oy` value. Real RGSS's stock `Spriteset_Map#update` reassigns
`tilemap.ox`/`oy` (and a fog `Plane`'s own ox/oy) unconditionally every
single frame, whether the camera moved or not — real RGSS treats this as a
cheap, hardware-composited draw offset, so the redundant reassignment costs
nothing there. This engine's `ox=`/`oy=` had no such guard, so a
**stationary** camera still paid a full re-composite every frame. Fixed by
adding a same-value early return to both setters on both classes (`tilemap_set_ox`/
`_oy`, `plane_set_ox`/`_oy`) — one frame's worth of camera position, camera
position, cheap to compare, wildly cheaper than the composite it used to
force every time regardless. Past this fix, the release now reaches real
event/battle content within seconds, not minutes.

That real content immediately needed three more, smaller fixes, each just
past where the last one stopped:

- **Fixed: `Audio.bgs_play` rejected RGSS3's 4th (`pos`) argument** — the
  same class of gap `Audio.bgm_play`'s `pos` argument fix (above) closed for
  BGM, left open for BGS. Real RGSS3's stock `RPG::BGS#play` passes `pos` the
  same way `RPG::BGM#play` does, but BGS's own backend
  (`Mix_PlayChannel`-based, `src/sdl_audio.cxx`) has no seekable position to
  resume the way `Mix_Music` does for BGM (this project's own earlier
  `RPG::BGM#replay` work already noted this: "BGS's own `pos` field exists
  for save-format fidelity, but its sample-channel backend never reports one
  to resume from"). Every VX Ace game whose event system plays a BGS via the
  stock 4-argument call raised `ArgumentError: wrong number of arguments
  (given 4, expected 1..3)` the moment it ran. Fixed by accepting a 4th
  `pos = 0` argument and warning once (`RGSS.warn_once`) if it is ever
  actually nonzero, rather than raising — matching the *first* step of BGM's
  own fix history, before real seeking was implemented there; BGS has no
  seekable backend to build the rest of that fix on.
- **Fixed: `Marshal.dump` called a custom `marshal_dump` with a stray
  argument.** A real bug in the vendored `mruby-marshal` gem (its own
  separate submodule, `take-cheeze/mruby-marshal` — not nested in
  `3rd/mruby`'s own gem tree, so it gets its own patch file the same way):
  `Marshal.dump` called a class's `marshal_dump` with one argument (a
  literal `nil`) instead of the zero arguments real Ruby's documented
  protocol defines for it — a leftover copy/paste from the `marshal_load`
  call two cases below it in the same function, which legitimately does take
  one argument (the dumped data). Found via a real VX Ace game's own
  `Game_Interpreter`, which defines a real, standards-conforming
  `marshal_dump` (RGSS3's own `BattleManager#save_battle_start_objects`
  reached the first time any event's "Battle Processing" command runs, to
  snapshot the interpreter's own state) — `ArgumentError: wrong number of
  arguments (given 1, expected 0)`, raised from inside
  `Game_Interpreter#marshal_dump` itself.
- **Fixed: `Marshal.load` called a custom `marshal_load` as a class method
  instead of real Ruby's instance-level protocol.** Fixing the argument
  count above immediately surfaced a second, deeper incompatibility in the
  same gem: `Marshal.load` called `SomeClass.marshal_load(data)` — a
  *class*-level factory method expected to return a whole new, fully-restored
  object — instead of real Ruby's actual protocol, which allocates a new
  instance *without* running `#initialize` (`Class#allocate`) and then calls
  the *instance* method `#marshal_load(data)` on that allocation to restore
  its state in place. `Game_Interpreter#marshal_load` is defined the real,
  standard way (an instance method), so calling it as a class method raised
  `NoMethodError: undefined method 'marshal_load' for Class`. Both fixes
  ship together as `patches/mruby-marshal-dump-load-protocol.patch` (that
  patch's own preamble has the full trail, including a CRuby confirmation of
  both directions and why this gem's own bundled test needed updating to the
  corrected protocol alongside the fix itself).

With all four of these in place, the same real release now runs its own
`BattleManager#setup` (a full object-graph `Marshal` round-trip) and reaches
into its bundled 吹きだしウィンドウ ("bubble window") speech-bubble add-on's
own event-driven call path — new ground for this whole investigation, not
reached even briefly before. It stopped there on a fifth, different-shaped
issue: `NoMethodError: undefined method 'defined?' for Module`, from inside
that add-on's own `call_sceman_hukidasi`, which guards a `SceneManager`
lookup with `defined?(SceneManager)`.

- **Fixed: the `defined?` keyword was not implemented at all.** Not a
  corner case in how some argument shape gets compiled, as first suspected
  — vendored mruby's lexer and grammar never recognized `defined?` as a
  keyword in the first place, so `defined?(expr)` always parsed as an
  ordinary method call named `defined?` and failed the moment it was
  actually called with a receiver, exactly as seen here. Confirmed real,
  not vendor-specific: upstream mruby 3.3.0 has never implemented this
  keyword either. This project's own maintainer had evidently started
  addressing it before this fix — the `NODE_DEFINED`/
  `mrb_ast_defined_node` AST scaffolding already existed in
  `mrbgems/mruby-compiler/core/node.h` — but the lexer, grammar, and a real
  codegen were never wired up; `codegen_defined` was a stub that
  unconditionally returned `nil`. `patches/mruby-defined-keyword.patch`
  (that patch's own preamble has the full trail) adds the missing keyword
  to the lexer and grammar (using `not`'s own two forms — `not expr` and
  `not(expr)` — as the direct structural template, since real Ruby's
  `defined?` has the same two forms) and replaces the codegen stub with
  real per-expression-type logic: `nil`/`true`/`false`/`self`, an
  already-declared local variable, and any assignment form are answered at
  compile time with zero evaluation (matching real Ruby's own behavior of
  never actually performing the assignment in `defined?(x = 1)`); constant
  reads reuse the normal read codegen wrapped in a compiler-generated
  rescue region (constant reads have no side effects, so discarding any
  exception is safe); method calls (including operators, which are
  `NODE_CALL` under the hood) answer via `respond_to?` rather than
  invoking the method, matching real Ruby's `defined?(raise "x")` =>
  `"method"` (never raises); instance/class/global variables and `yield`
  each answer via a single boolean-returning self-send; and anything else
  (literals, `if`/`case` used as an expression, etc.) defaults to
  `"expression"`, matching real Ruby's own default. Every expected value
  was checked directly against a real CRuby 3.3.6 interpreter, not from
  documentation alone — see the dedicated regression test in
  `mruby-rgss/test/test.rb` for the full table and the two documented,
  intentional simplifications versus real Ruby (both safe: neither ever
  evaluates anything with side effects).

  With this fix in place, the same real release no longer crashes here at
  all: attaching gdb to a running headless instance mid-boot shows it
  inside `Graphics.update`'s own frame-throttling `nanosleep`, i.e.
  genuinely executing its normal per-frame game loop rather than stuck or
  crashed. It turns out the absence of `[RPGXP-HOST-SCENE]` logging was not
  a sign of a slow title screen: under `--test_play`, this release's own
  `Main` script skips straight to `Scene_Battle#start` (RGSS3's own
  `$BTEST`-gated Test Battle convention, which VX Ace's editor triggers via
  F9) without ever constructing a `Scene_Title`, which surfaced the next
  bug below immediately.

- **Fixed: `Window#viewport=` was not implemented at all.** `Scene_Battle`'s
  own stock `create_info_viewport`/`create_all_windows` assign every battle
  window (`Window_BattleStatus` among them) to a dedicated Viewport so they
  clip and scroll with the battle background, the same way RGSS3 (VX Ace)
  lets any `Window` be (re)assigned to a `Viewport` after construction —
  this engine's native `Window` class had no `viewport`/`viewport=` method
  at all, so the very first battle window construction raised
  `NoMethodError: undefined method 'viewport=' for Window_BattleStatus`.
  Not a documented, deliberate gap: `Window#initialize` already threads an
  optional viewport argument through to the same `parent_object` helper
  `Sprite`/`Plane`/`Tilemap` use at construction (VX Ace's own
  `Window.new(x, y, width, height)` shape just never passes one, so that
  path was silently dead), and the shared z-order pass in `gfx_update`
  already groups every display object by its *live* LVGL parent each
  frame — so reassignment only needed one new native method,
  `window_set_viewport` (`mruby-rgss/src/lib.cxx`), reparenting the
  window's canvas via LVGL's own `lv_obj_set_parent` (clipped and scrolled
  by the target viewport's content layer exactly like a Sprite, or back to
  the root screen for `nil`) and updating the z-order. No compositing,
  clipping, or z-sort changes needed elsewhere. With this fix, the same
  real release's headless run no longer crashes within the first several
  minutes of `Scene_Battle`, well past this wall.

- **Fixed: `RPG::UsableItem#battle_ok?`/`#menu_ok?` were not implemented at
  all.** Once past the `Window#viewport=` wall, the same real release's
  enemy AI hit a seventh: `NoMethodError: undefined method 'battle_ok?' for
  RPG::Skill`, from `Game_BattlerBase#occasion_ok?` deciding whether an
  enemy's skill is usable during `Game_Enemy#make_actions`. RGSS3's own
  stock `occasion_ok?` dispatches on these two methods rather than
  comparing the `occasion` field directly (`item.battle_ok?` in battle,
  `item.menu_ok?` from the menu) — confirmed against RPG Maker MV's own
  `rpg_objects.js` (`Game_BattlerBase.prototype.isOccasionOk`, a line-for-
  line port of VX Ace's Ruby that inlines the same two checks:
  `occasion === 0 || occasion === 1` for battle, `occasion === 0 ||
  occasion === 2` for the menu). This engine's `RPG::UsableItem` (the real
  ancestor of `RPG::Skill`/`RPG::Item` — confirmed via
  `mruby-rpgxp/mrblib/rgss_data.rb`'s own `class Skill < UsableItem`
  declaration, VX Ace's `rgss2_data.rb` only reopens it to add fields, not
  redeclaring the hierarchy) had the `occasion` field itself but never the
  two convenience methods real games' own default scripts call. Added as
  two small mrblib methods on `UsableItem`
  (`mruby-rpgvx/mrblib/rgss2_data.rb`), matching the editor's Occasion
  dropdown exactly (0 Always, 1 Only in Battle, 2 Only from the Menu, 3
  Never). With this fix, the same real release's headless Test Battle run
  gets past its enemies' very first action-selection pass with no crash.

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
only item left in the six sections above; item 7's `$!`/bare-`raise` gap is
now fixed too (`patches/mruby-dollar-bang-scoped.patch`, above), so the same
real release's own crash-reporter add-on now sees the actual exception
instead of masking it behind an unrelated `NoMethodError`, and re-raises it
correctly. Eighteen real bugs have been found and fixed this way so far
(`Dir.glob`, `Color.new`/`Tone.new`, the desktop heap, `Window#contents`,
`Audio.bgm_play`'s `pos` argument, `RPG::CommonEvent#autorun?`/`#parallel?`,
`Bitmap#draw_text`'s non-`String` coercion, `RPG::EventCommand#initialize`,
`Sprite#width`/`#height`, the `::Const = value` compiler bug, `$!`/bare-
`raise` itself, the `Tilemap`/`Plane` `ox=`/`oy=` redundant-refresh hang,
`Audio.bgs_play`'s `pos` argument, `Marshal`'s `marshal_dump`/
`marshal_load` protocol mismatches, the missing `defined?` keyword, the
missing `Window#viewport=`, and the missing
`RPG::UsableItem#battle_ok?`/`#menu_ok?`) — the first ten via the temporary
VM probe, finding the real exception directly regardless of `$!` being
masked at the time. With `defined?`, `Window#viewport=` and
`battle_ok?`/`menu_ok?` all fixed, the same real release's headless Test
Battle run now gets past its enemies' first action-selection pass with no
crash at all; where its next wall stands (if any) past that is not yet
traced.
