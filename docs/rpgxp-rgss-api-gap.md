# RGSS API gap for the script host

The [RGSS script host](adr/0017-rpgxp-rgss-script-host.md) runs an RPG Maker XP
project's own `Data/Scripts.rxdata` unmodified. The scripts assume the engine
(normally `RGSS104E.dll`) supplies the RGSS class library; this project supplies
it as `mruby-rgss` natively, plus the three Ruby classes the player also ships
(`mruby-rpgxp/mrblib/rgss_library.rb` — see gap 0). This document tracks **what
the stock scripts call** versus **what the engine provides**. The gaps that
blocked a default-on host have closed and running a game's own scripts is now
the **only** way an XP project runs — the reimplemented engine that used to stand
in for them is gone ([ADR 0030](adr/0030-rgss-only-the-games-own-engine.md)). So
this list is the whole XP roadmap: every entry is something a real game asked for
and did not get, and what a boot check reports is what goes in it.

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
- **`Graphics`** — `frame_count`, `frame_rate`, `update`, and `snap_to_bitmap` /
  `freeze` / `transition`: the scene transition draws, as RGSS's default
  dissolve of the frozen still over the incoming scene (see item 3 of the
  [VX gap](rpgvx-rgss-api-gap.md), where it landed — the code is shared).
  `transition`'s `filename`/`vague` form dissolves through the transition
  graphic, so a battle transition is the shape its author drew rather than a
  fade. _`frame_reset` is still a `warn_stub` no-op._
- **`Input`** — all key constants (`A`/`B`/`C`/`X`/`Y`/`Z`/`L`/`R`/`UP`…`F9`),
  `update`, `press?`, `trigger?` (~68), `repeat?` (~34), `press`/`release`,
  `dir4`/`dir8`.
- **`Audio`** — `bgm/bgs/me/se` `play`/`stop`/`fade` (+ `bgm_pos`/`bgs_pos`), all
  used and resolved through `GAME_DIR`/`RTP_DIR`.
- **`Viewport`** — `new` (~7), `ox`/`oy`, `rect`, `z`, `visible`, `update`,
  `dispose`.
- **Kernel** — `load_data` (~27) and `save_data` are supplied by the script host
  (`Object#load_data`/`#save_data` → the project database); `rand` (~36) and
  `Integer()` come from the `mruby-random` / `mruby-kernel-ext` core gems, which
  had to be added to the build (see gap 0e — neither is in mruby's default set,
  and this list called `rand` "core" until a game proved otherwise).

## Gaps ❌ / ⚠️ (ordered by how much they block a boot)

### 0. The RGSS standard library — `RPG::Sprite`, `RPG::Weather`, `RPG::Cache` ✅ (was the first thing that stopped a boot)

Measured, not counted: with the host on, the test bed used to get 21 sections in
before

```
[RGSS] script host: section "Sprite_Character" raised NameError: uninitialized constant RPG::Sprite
```

None of these three is **in the script bundle** — the 90 sections of the
`OpenGame.exe` bed define no such section, because `RGSS104E.dll` supplies them.
`Sprite_Character < RPG::Sprite` was therefore the first line of the game's own
engine that could not run, with everything downstream (`Spriteset_Map`,
`Scene_Map`, `Main`) behind it, and `RPG::Cache` — which every graphic a game
loads goes through — behind that at runtime.

They are plain Ruby in the real player too, so they are plain Ruby here:
**`mruby-rpgxp/mrblib/rgss_library.rb`**, transcribed from the definitions the
RGSS Reference Manual publishes, on top of the native `mruby-rgss` primitives.

- **`RPG::Sprite`** — a `Sprite` subclass adding the battle/animation behaviour:
  `damage(value, critical)` (the floating damage number, white / green for
  recovery / `CRITICAL` above it, arcing up and fading over 40 frames),
  `animation(animation, hit)` and `loop_animation` (an `RPG::Animation` played
  over the sprite through 16 cell sprites at z 2000, with the frame timings' SE
  and flash), `blink_on`/`blink_off`/`blink?`, `effect?`, and the battler
  transitions `whiten`/`appear`/`escape`/`collapse` — all advanced by its own
  `update`, and its animation cells carried along when the sprite moves.
- **`RPG::Weather`** — rain, storm and snow: 40 recycled drop sprites over three
  bitmaps the class draws for itself.
- **`RPG::Cache`** — the bitmap cache every `RPG::Cache.character` /
  `.tile` / `.windowskin` call in a game goes through, including cutting a 32x32
  tile out of a tileset and building hue-rotated variants.

Three deliberate deviations, all forced by this engine and listed in the file's
header: colours are re-assigned rather than mutated in place (our compositor
snapshots on assignment), a hue variant is re-loaded rather than `clone`d (a
native handle must not be shallow-copied), and an asset that will not load gives
a blank bitmap with a warning instead of raising (a game whose RTP is missing
must not die on its first graphic).

With those three in place the host runs a game's whole bundle — **all 103
sections of the released *Pray for You*** — and reaches `Main`, where it met the
next one:

### 0b. `Errno::ENOENT` ✅ (an unresolvable rescue clause eats every exception)

The editor writes this into the `Main` section of *every* project:

```ruby
begin
  $scene = Scene_Title.new
  $scene.main while $scene != nil
  Graphics.transition(20)
rescue Errno::ENOENT
  print("Unable to find file #{$!.message.sub("No such file or directory - ", "")}.")
end
```

mruby ships no `Errno` (no `mruby-errno` gem is vendored or configured). A rescue
clause is evaluated when an exception passes through it, so *any* exception
leaving the game loop — including the timeout a headless run ends on — came back
as `NameError: uninitialized constant Errno`, which reads as "the game crashed"
when the game was running fine. `rgss_library.rb` defines `Errno::ENOENT` (plus
`EACCES`/`EEXIST`/`EINVAL`/`EISDIR`, so a script rescuing one of those does not
hit the same trap) and `SystemCallError`, each only when absent — the file is
loaded under CRuby too, where the real ones exist. `RGSSData#read_object` now
raises `Errno::ENOENT` with RGSS's own message shape, so the handler above
prints the filename it was written to print.

### 0c. `Bitmap#draw_text`'s Rect form ✅ (the first window a game opens)

RGSS overloads `draw_text` the way it overloads `fill_rect`:

```ruby
draw_text(x, y, width, height, str[, align])
draw_text(rect, str[, align])
```

Only the first was implemented, and `Window_Command#draw_item` — the menu every
title screen is built from — calls the second, so a game died at its first window
with `ArgumentError: wrong number of arguments (given 2, expected 5..6)`. The
native method now takes both, on the same `mrb_get_argc` branch `fill_rect`
already used.

Worth noting how this was found and bounded: `MRB_ARGS_*` does not enforce
anything — the `mrb_get_args` format string does — so the arities a game can
actually call are the union of the format strings in each native function. A
sweep comparing every call site in both beds' bundles (193 sections) against
those formats reports no other mismatch, and the calls it does resolve include
the other overloaded ones (`fill_rect`, `gradient_fill_rect`, `blt`,
`stretch_blt`), which were already right.

### 0d. `Input.trigger?` in a game's own loop ✅ (nothing a game could be *played* with)

An RGSS scene loop reads input right after refreshing it:

```ruby
loop { Graphics.update; Input.update; update; break if $scene != self }
```

This engine drained the backends' buffered key transitions inside
`Graphics.update`, and `Input.update` expires the previous frame's triggers — so
every key applied on the first line was wiped by the second before the scene read
it on the third. `Input.trigger?` was **permanently false** for a game running
its own engine: no New Game on its title screen, no message advance, no menu.
Only held state (`press?`, and so `dir4`/`dir8` movement) worked.

RGSS's contract is that `Input.update` is what refreshes input, so the drain
moved there (`RGSS::Input._poll`, native): expire the old triggers, apply this
frame's transitions, then run the repeat bookkeeping. The built-in RPG2000/XP
flows and the MV/MZ bridges call `Input.update` once a frame too, so their timing
is unchanged.

`--rgss_host_new_game` then makes a headless run *play*: it taps confirm through
the same buffer the SDL backend feeds, and every scene the game reaches is logged
as `[RPGXP-HOST-SCENE]` (read from the game's own `$scene` global). Reaching a
second scene is what `scripts/rpgxp_boot_check.bash` now asserts — the proof that
a game's engine took a keypress and acted on it, rather than merely drawing.

`--rgss_host_move_test` and `--rgss_host_menu_test` are the two rungs above that,
run in the same pass: walk the party across the game's own passability
(`[RPGXP-HOST-MOVE]`), then press cancel and report where the game went
(`[RPGXP-HOST-MENU]`). The menu matters here because it is the first thing a game
draws out of its *own* `Window_Base` subclasses, its own windowskin, its own font
and its own `Bitmap#draw_text`, none of which a map scene touches. The editor bed
passed it first time — and then, with the confirm taps still running, walked on
into its own `Scene_Item`:

```
[RPGXP-HOST-SCENE] Scene_Map frame=41
[RPGXP-HOST-MOVE] start=9,7 end=9,8 moved=true frame=221
[RPGXP-HOST-SCENE] Scene_Menu frame=242
[RPGXP-HOST-MENU] scene=Scene_Menu opened=true frame=301
[RPGXP-HOST-SCENE] Scene_Item frame=321
```

`--rgss_host_battle_test` is the rung above *that*, and takes its own pass: a
battle is called from the map, and the pass above ends inside the menu. It sets
the same five `$game_temp` fields the stock `Interpreter#command_301` does — the
only probe here that writes to a game's globals rather than just reading them,
because no keypress starts a battle — and reports `[RPGXP-HOST-BATTLE]`. It is
the biggest surface of the lot: a battle builds the game's own
`Spriteset_Battle`, so every enemy is a `Sprite_Battler` on top of the
`RPG::Sprite` in gap 0, whose transitions, damage pop-up and animation playback
nothing had run before. Whatever it reports is the next entry here.

### 0e. `Kernel#Integer()` ✅ (the first thing New Game runs)

With input working, both beds get *into* the game — and stop where every RGSS
game builds its party: `Game_Battler_1` clamps each stat through
`n = [[Integer(n), 1].max, 999999].min`, and mruby's `Kernel#Integer` lives in
the **mruby-kernel-ext** core gem, which was not in the build. Added to
`build_config.rb` and depended on in `mruby-rpgxp/mrbgem.rake` (the dependency
edge orders its initialization, the same reason `mruby-sprintf` is declared
there), with an availability test so its absence fails in the test binary rather
than on a player's New Game. The same gem supplies `Float()` / `String()` /
`Array()`, which neither stock bundle uses but community scripts do.

A failure inside a game's own scripts now also prints **where**: the host reports
up to a dozen backtrace frames with the section name and line
(`Game_Battler_1:61`), since each section is evaluated under its editor name.
Past the title screen, "Main raised NoMethodError" can otherwise mean any of a
hundred scripts. It paid for itself on the next run, naming both of these:

### 0f. `Kernel#rand` ✅ (the first thing New Game does after building the party)

```
[RGSS] script host: section "Main" raised NoMethodError: undefined method 'rand' for Game_Player
[RGSS] script host:   from Game_Player:88:in make_encounter_count
[RGSS] script host:   from Game_Player:57:in moveto
[RGSS] script host:   from Scene_Title:134:in command_new_game
```

`Game_Player#make_encounter_count` rolls `rand(n) + rand(n) + 1` as the party is
placed. `Kernel#rand` is the **mruby-random** core gem, which was not in the
build: this engine's own code uses seeded LCGs instead, because its runs are
diffed frame by frame against the genuine runtimes, so nothing here had ever
needed it (`RPG::Weather` scatters its drops with `rand` too — that would have
been the next report). Added to `build_config.rb` with the dependency edge in
`mrbgem.rake`.

### 0h. `#clone` / `#dup` on the value types ✅ (where a game's screen tone stopped it)

With `rand` and the table write fixed, both beds reach **`Scene_Map`** — the test
bed goes `Scene_Title → Scene_Map` and runs to the timeout, the released game
`Scene_logo → Scene_Title → Scene_Map`. The next report:

```
[RGSS] script host: section "Main" raised TypeError: uninitialized RGSS::Tone
[RGSS] script host:   from Game_Screen:102:in red
[RGSS] script host:   from Game_Screen:102:in update
```

`Game_Screen#start_tone_change` keeps `@tone_target = tone.clone`, and mruby's
`clone`/`dup` allocate a bare object of the same class and copy only its
instance variables — so a cloned `Color`/`Tone`/`Rect`/`Table` carried no native
payload and the first read of it raised. Both call `initialize_copy` on the new
object, which the four value types now define. Games do this constantly (the
screen tone, the flash colour, a map's fog tone, a picture's tone), so it is on
the path of anything that tints the screen.

**`Bitmap#clone` ✅, closed after the fact.** It was the one member of this family
a payload copy could not fix: a `Bitmap` owns a pixel buffer, so a copy that
shared it would have been worse than one with no payload at all. RGSS's own
`RPG::Cache` builds every hue variant with
`@cache[key] = @cache[path].clone; @cache[key].hue_change(hue)` — one decode per
file however many hues a game asks for — and `hue_change` rewrites the buffer in
place, so a shared buffer would recolour the cached original along with the
variant. `initialize_copy` now copies the pixels, marks the copy dirty so
anything already showing it repaints, and gives it its own `Font` so a size or
colour set on the clone cannot reach back. `rgss_library.rb`'s `RPG::Cache` is
the published definition again — the "reloads for a hue variant" deviation is
gone from its header.

### 0g. `Table#[]=` past the edge ✅ (a write RGSS drops, we raised on)

```
[RGSS] script host: section "Main" raised TypeError: true cannot be converted to Integer
[RGSS] script host:   from map_light:265:in []=
```

*Pray for You*'s `map_light` script walks `for x in 0..(self.width)` — inclusive,
so one past the edge — and runs `@passages_data[x, y] |= 0x0f`. Out there the
read answers `nil`, `nil | 0x0f` is `true`, and that `true` arrives as the value
of a write RGSS was always going to ignore. `Table#[]=` converted its arguments
before the bounds check, so it raised instead of dropping the write. The bounds
check now comes first and the value is converted only when it is going to be
stored; an *in-range* write of a non-Integer still raises. Out-of-range **reads**
keep answering `nil` — the stock scripts test for exactly that
(`tile_id = self.data[x,y,i]; if tile_id == nil`).

**This gap was invisible for a long time**, for two compounding reasons: the
switch that turns the host on could not work in a built engine (see the note at
the end of this document), and `scripts/rpgxp_script_host_check.rb` *stubbed*
`RPG::Sprite` with an empty class and evaluated only a hand-picked logic subset,
so it stayed green throughout. That harness now loads the real
`rgss_library.rb`, evaluates **every** section except `Main`, and drives the
effects, the animation, the weather and the cache against fakes for the native
classes only.

### 0i. `Math` ✅ (the first jump on a game's own map)

With the input path live, both beds walk their own maps — the test bed
`start=9,7 end=9,8 moved=true`, *Pray for You* `start=1,0 end=12,14` — and the
released game's opening then stopped here:

```
[RGSS] script host: section "Main" raised NameError: uninitialized constant Game_Character::Math
[RGSS] script host:   from Game_Character 3:328:in jump
[RGSS] script host:   from map_light:752:in move_type_custom
[RGSS] script host:   from Game_Character 1:117:in force_move_route
[RGSS] script host:   from Interpreter 5:201:in command_209
```

`Game_Character#jump` is **stock RMXP** — it sizes its arc with
`Math.sqrt(x_plus * x_plus + y_plus * y_plus).round` — so this is not a
*Pray for You* peculiarity: every game reaches it the first time an event, a move
route or a Set Move Route command jumps. mruby keeps `Math` in its own core gem
(`mrbgems/math.gembox`), which was not in the build; added to `build_config.rb`
with the dependency edge in `mrbgem.rake`, and an availability test in
`mruby-rpgxp/test/rpgxp_test.rb`.

Worth noting *how* it hid: the CRuby harness cannot catch a missing mruby core
gem, because CRuby has `Math`. Every gap of this family (`sprintf`, `Integer()`,
`rand`, now `Math`) is only ever found by a booted game, which is the argument
for the boot check getting a game as far as possible rather than asserting early.

**`Time` was fixed in the same change, without waiting for its report.** Both
script bundles were then swept for the standard library they call, which turned
up one more absence: stock `Scene_Load` seeds its newest-save search with
`Time.at(0)` and `Window_SaveFile` stamps each slot with `File#mtime` — and
mruby-io's `File#mtime` answers a `Time`, while `mruby-time` is only a *test*
dependency of mruby-io and so was not linked. Every game's save and load screens
need it. The rest of the sweep came back clean: `Marshal` (mruby-marshal),
`File`/`FileTest` (mruby-io) and `Regexp` (mruby-onig-regexp) are all linked, and
neither bundle touches `Dir`, `Struct`, `Set`, `ObjectSpace` or the metaprogramming
gems.

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

### 3. `Tilemap` ⚠️ (tiles + animated autotiles + interim priority split rendered)

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
maps do no per-frame work. **Priority split (interim):** `priorities=` (native)
routes each tile by its `priorities[id]` value — priority-0 tiles into the ground
canvas, priority ≥ 1 tiles into a second **"above" canvas** that is a companion
z-ordered object (created in `tilemap_init`, torn down by the native
`Tilemap#dispose`) sorting above the character sprites (`TILEMAP_ABOVE_Z`). So
roofs and tree crowns now draw over the party. This is an **interim flat
approximation**: it puts *every* priority tile above *every* character, not only
the ones on lower rows, and the above layer's single `z` is a best guess (above
characters, below fog) pending in-game confirmation. The correct **per-row**
scheme — above-priority tiles as per-row `z` strips that interleave with
characters — is designed in
[ADR 0022](adr/0022-rpgxp-tilemap-priority-layering.md) and remains the follow-up.
`tileset=`, `map_data=`, `priorities=`, `ox=`/`oy=`, `z=`, `update`,
`visible`/`visible=`, `dispose`/`disposed?` are native and re-render on change.
`visible=` hides the above layer along with the ground. **Remaining:** the per-row
priority scheme (ADR 0022); `z=` on the tilemap does not yet shift the above
layer's fixed `z`; and `flash_data` is still ignored.

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
`mruby-rpgxp/test` availability check. `exit` (1 use, from `Interpreter`, which
calls it to abort on runaway common-event recursion) is now provided by the
`mruby-exit` core gem — it raises a catchable `SystemExit` that the script-host
driver ends the game on (see item 3 above / ADR 0023).

## Notes

- **The host is how a game runs** ([ADR 0029](adr/0029-rgss-script-host-by-default.md)
  made it the default, [ADR 0030](adr/0030-rgss-only-the-games-own-engine.md) made
  it the only path); `--norgss_script_host` loads a project without running it,
  which is an inspection tool, not a second engine. The last blocker before the
  flip was reconciling the scripts' blocking
  `$scene.main while $scene` loop with the web build's per-frame
  `emscripten_set_main_loop` callback
  (the desktop build blocks fine; the web build calls `RPGXP#main_loop` once per
  browser frame, so an unmodified blocking script loop would hang the tab). This
  is now **implemented** ([ADR 0023](adr/0023-rpgxp-script-host-frame-driver.md)):
  when the host is enabled, `RPGXP` runs `Main` inside an mruby `Fiber` and the
  wrapped `Graphics.update` yields it once per frame, so `main_loop` drives one
  game frame per browser callback. `exit` (used by the `Interpreter`) is now
  wired too — it raises a `SystemExit` the driver ends the game on. The remaining
  step is to boot a real project under the **web** build and confirm it end to
  end; the native beds are booted under the host by
  `scripts/rpgxp_boot_check.bash` in CI, which taps confirm on each game's own
  title screen, asserts it reaches a second scene, and walks the party on the
  editor bed's map.
- None of the native items above can be built or run in the current CI sandbox;
  each is verified by `mruby-rgss/test` (compiled and run in CI) plus the
  host-side `scripts/rpgxp_script_host_check.rb`. The Ruby half (gap 0) is
  verified for real by that harness — it loads `rgss_library.rb` itself rather
  than stubbing it, which is the mistake that let gap 0 hide.

## Why this list was never measured in the engine

Until now the host could only be turned on by the `RGSS_SCRIPT_HOST` environment
variable, and **this mruby build has no `ENV`** — no `mruby-env` gem is in
`build_config.rb`, and none is vendored. `ScriptHost.enabled?` therefore returned
false in every built engine, on every target, and the host never ran. Only the
CRuby harnesses, where `ENV` does exist, ever exercised the switch, which is why
the dead opt-in went unnoticed while the documents kept naming it.

`--rgss_script_host` (published to the Ruby side as the `RGSS_SCRIPT_HOST`
constant, the way `--rpgxp_new_game` is published as `RPGXP_NEW_GAME`) is the
switch that works. The environment variable is still honoured for the harnesses.
With it, the gaps above stop being static call counts and become what actually
stops a boot — the section name is now reported with the failure.
