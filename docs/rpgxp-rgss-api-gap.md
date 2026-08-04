# RGSS API gap for the script host

The [RGSS script host](adr/0017-rpgxp-rgss-script-host.md) runs an RPG Maker XP
project's own `Data/Scripts.rxdata` unmodified. The scripts assume the engine
(normally `RGSS104E.dll`) supplies the RGSS class library; this project supplies
it as `mruby-rgss`. This document tracks **what the stock scripts call** versus
**what `mruby-rgss` provides**, so the host can be turned on by default once the
gaps close.

The "needed" column is derived from the real `data/OpenGame.exe/Testbed/XP`
scripts (all 90 sections), by counting method/`.new`/constant usage — see the
analysis approach in `scripts/rpgxp_script_host_check.rb`. Frequencies are
approximate call counts across the bundle.

## Already provided ✅

These are complete enough for the stock scripts:

- **Value types** — `Table`, `Color`, `Tone`, `Rect` (native, with RGSS Marshal).
- **`Bitmap`** — `new`, `draw_text` (~96), `fill_rect`, `gradient_fill_rect`,
  `blt`, `stretch_blt`, `clear` (~33), `text_size`, `get_pixel`/`set_pixel`,
  `rect`, `width`/`height`, `font`, `hue_change`, `dispose`. _Complete for the
  stock scripts._
- **`Font`** — instance `name`/`size`/`bold`/`italic`/`shadow`/`outline`/`color`/
  `out_color`, class defaults (`default_name`/`default_size`/…), `exist?`.
- **`Graphics`** — `frame_count`, `frame_rate`, `update`. _`freeze`,
  `transition`, `frame_reset` exist but are `warn_stub` no-ops: the game runs but
  the fade/transition is not drawn._
- **`Input`** — all key constants (`A`/`B`/`C`/`X`/`Y`/`Z`/`L`/`R`/`UP`…`F9`),
  `update`, `press?`, `trigger?` (~68), `repeat?` (~34), `press`/`release`,
  `dir4`/`dir8`.
- **`Audio`** — `bgm/bgs/me/se` `play`/`stop`/`fade` (+ `bgm_pos`/`bgs_pos`), all
  used and resolved through `GAME_DIR`/`RTP_DIR`.
- **`Viewport`** — `new` (~7), `ox`/`oy`, `rect`, `z`, `visible`, `update`,
  `dispose`.
- **Kernel** — `load_data` (~27) and `save_data` are supplied by the script host
  (`Object#load_data`/`#save_data` → the project database); `rand` (~36) is core.

## Gaps ❌ / ⚠️ (ordered by how much they block a boot)

### 1. `Sprite` extended properties ✅ (opacity/zoom/angle/mirror/tone/color/src_rect/blend_type/bush_depth/flash all rendered)

`mruby-rgss` `Sprite` has `bitmap`/`bitmap=`, `x`/`x=`, `y`/`y=`, `z`/`z=`,
`visible`/`visible=`, `dispose`, `update`, and stores the extra properties the
stock scripts set — `opacity` (~18), `ox`/`oy`, `zoom_x`/`zoom_y` (~3 each),
`angle`, `mirror`, `tone`, `color`, `blend_type`, `bush_depth` (~2), `src_rect`
and `flash` — with RGSS defaults (`mruby-rgss/mrblib/lib.rb`).

**`opacity`, `zoom_x`/`zoom_y` and `angle` are now rendered natively.** A Sprite's
native handle is an `lv_canvas` (an LVGL image subclass), so: `Sprite#opacity=`
sets the canvas's LVGL object opacity (the compositor multiplies the bitmap's
alpha by it, so fades actually fade); `Sprite#zoom_x=`/`zoom_y=` set the image's
scale (`lv_image_set_scale_x/y`, where 256 = 1.0), so the sprite scales;
`Sprite#angle=` sets the image's rotation (`lv_image_set_rotation`, converting
RGSS's counter-clockwise degrees to LVGL's clockwise 0.1° units, pivoting on the
sprite's `ox`/`oy` origin); `Sprite#mirror=` re-binds the canvas to a
horizontally-flipped scratch copy of the bitmap (LVGL's `lv_image` has no flip,
so mirroring is a software pass); `Sprite#tone=`/`color=` bake an RGSS tone (grey
desaturation + RGB offset) and a colour overlay into that same scratch copy per
pixel; and `Sprite#src_rect=` crops the display to a sub-rectangle (the scratch
is that region, reused across frames to avoid GC churn). `Sprite#update` is native
and re-composites when a `src_rect` is set, so the per-frame `src_rect.set` that
character sprites do actually changes the shown cell. Crop/mirror/tone/colour
share one pre-composite (`spr_bind_display`). `Sprite#blend_type=` maps 0/1/2 to
the canvas object's LVGL blend mode (normal / additive / subtractive), so
additive effects composite;
`Sprite#bush_depth=` fades the bottom N rows to half opacity in the same
pre-composite, so a character wading through bushes dims below the waist; and
`Sprite#flash(color, duration)` runs a timed colour pulse — a colour flash
overlays that colour at a fading alpha, a nil-colour "empty" flash blinks the
sprite out, and `update` decays it one frame at a time until it clears. So all of
`Sprite_Character`, `Sprite_Battler`, `Arrow_Base`, the weather sprites and the
battle animation player now get their full visual treatment. **Snapshot caveat:**
a sprite that redraws its bitmap, or mutates tone/colour in place, still needs a
re-assign (`bitmap=`/`tone=`/`color=`) to re-composite unless it also has a
`src_rect` or an active flash (which re-composite via `update`).

### 2. `Window` ⚠️ (background + frame + contents + cursor + pause rendered)

`Window` is now **native** (`mruby-rgss/src/lib.cxx`): `Window.new` creates an
`lv_canvas` the size of the window and `window_refresh` composites it — when a
`windowskin` is set it stretches the 128×128 background tile at `(0,0)` over the
window at `back_opacity` and draws the 64×64 frame at `(128,0)` as a 9-slice
(16px corners) at `opacity`, then blits the `contents` `Bitmap` into the content
area (inset 16px, scrolled by `ox`/`oy`) at `contents_opacity`. The compositing
reuses the tested `Bitmap#clear`/`#stretch_blt`/`#blt` via `mrb_funcall`; only the
RMXP windowskin source rects are new. `contents=`, `windowskin=`, `x=`/`y=`,
`width=`/`height=`, `ox=`/`oy=`, `opacity=`/`back_opacity=`/`contents_opacity=`,
`z=`, `visible`/`visible=`, `dispose`/`disposed?` are native. It also draws the
**blinking cursor** 9-slice at `cursor_rect` (when `active`) and the **pause
arrow** (when `pause`); `Window#update` advances the blink/pause animation and
redraws (also picking up in-place `cursor_rect` mutation, which scripts do via
`cursor_rect.set`). The cursor is a crisp **9-slice** with 2px corners (matching
RMXP/mkxp's `buildFrame`): the four corners copy 1:1, the four edges stretch along
one axis and the centre fills the rest, so the selection box keeps a sharp border
at any size. So the whole menu/message/shop/battle UI renders — framed windows,
text, selection cursor and message pause. The content blit already clips to the
content area (its source rect is the content-area size, so taller `contents` are
cropped and scrolled, not overflowed). `stretch=` picks between the stretched
(default) windowskin background and a tiled one (the 128×128 tile repeated at 1:1
across the window). **Remaining:** the RMXP windowskin source-rect constants are
best-effort until a game exercises them.

### 3. `Tilemap` ⚠️ (tiles + animated autotiles rendered; priority layering pending)

`Tilemap` is now **native** (`mruby-rgss/src/lib.cxx`): `Tilemap.new` creates an
`lv_canvas` the size of the viewport (or screen) and `tilemap_refresh` draws the
visible part of the map — for each of the three `map_data` layers it blits the
tiles overlapping the viewport (given `ox`/`oy`). **Regular tiles** (id ≥ 384)
come straight from the `tileset`; **autotiles** (id 48–383) are assembled from
their four 16×16 quads using the RMXP 48-shape quad table (`AUTOTILE_QUADS`,
derived from mkxp), so water/terrain ground now fills in. **Animated autotiles**
(a wider autotile bitmap holds several 96px frames side by side) now cycle:
`Tilemap#update` advances a counter whose frame index is `counter / 16` (mod 4,
matching RMXP/mkxp's 16-tick-per-frame `atAnimation` table), and the renderer
shifts the autotile source into that frame's column — so water and waterfalls
animate. `update` only re-tiles on a frame boundary, and only when the map
actually has an animated autotile (recorded during the last refresh), so static
maps do no per-frame work. `tileset=`, `map_data=`, `ox=`/`oy=`, `z=`, `update`,
`visible`/`visible=`, `dispose`/`disposed?` are native and re-render on change.
**Remaining:** the per-tile **priority layering** (`priorities`) — tiles that
should draw above characters — is stored-only, so everything still renders on one
flat layer. A correct fix needs the above-priority tiles to become their own
z-ordered objects that interleave with character sprites per row; the design is
worked out in
[ADR 0022](adr/0022-rpgxp-tilemap-priority-layering.md) (per-row `z` strips as
companion z-objects) and is held for review before it lands, because it mints new
z-ordered objects and a custom dispose path that can only be verified in a running
game. `flash_data` is also still ignored.

### 4. `Plane` ✅ (tiling + scroll + tint/blend + zoom all rendered)

`Plane` is now **native** (`mruby-rgss/src/lib.cxx`): `Plane.new` creates an
`lv_canvas` the size of the viewport (or screen) whose buffer is filled by tiling
the `bitmap` with the `ox`/`oy` scroll wrapped around it (`plane_retile`), so map
parallax and fog now actually tile and scroll. `bitmap=`, `ox=`/`oy=`,
`opacity=`, `tone=`, `color=`, `blend_type=`, `zoom_x=`/`zoom_y=`, `z=`,
`visible`/`visible=`, `dispose`/`disposed?` are native. `opacity=` and
`blend_type=` map onto the plane canvas's LVGL object (so a fog Plane can fade and
composite additively); `tone=`/`color=` bake an RGSS tone (grey desaturation + RGB
offset) and a colour overlay into the tiled buffer per pixel (the same maths
Sprite uses) — so a tinted fog renders its tint; and `zoom_x=`/`zoom_y=` scale the
tiled pattern (nearest-neighbour: the source is sampled at the reciprocal rate,
with a zoom of 1.0 staying on the fast integer path). The canvas is invalidated
directly on each re-tile. **Remaining:** none for correctness — the per-scroll
re-tile is a full-canvas `bmp_read`/`bmp_put` pass, so a dirty-rect or
offset-based scroll is a possible optimization.

### 5. `Kernel#sprintf` / `String#%` ✅ (mruby-sprintf gem)

Scripts use `sprintf` (~9, e.g. `%02d`/`%04d` clocks and ids, `%+d`, `%0*d`).
The `mruby-sprintf` core gem is now in the build (`build_config.rb`), providing
`Kernel#sprintf`/`#format` and `String#%`. Covered by the gem's own tests plus a
`mruby-rpgxp/test` availability check. `exit` (1 use, from `Interpreter`) is
still assumed and not yet provided.

## Notes

- Turning the host on by default also requires reconciling the scripts' blocking
  `$scene.main while $scene` loop with the emscripten frame loop (Asyncify or a
  per-frame `Scene#main` driver) — see ADR 0017.
- None of the above can be built or run in the current CI sandbox; each item is
  verified by `mruby-rgss/test` (compiled and run in CI) plus the host-side
  `scripts/rpgxp_script_host_check.rb`.
