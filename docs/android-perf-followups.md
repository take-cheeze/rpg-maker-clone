# Android performance follow-ups (handoff)

Where the Android port's frame-rate work stands after the present-path tuning,
the map-scene redraw skips, the `blt_quads` batching (#1364) and the opaque-row
`memcpy` fast path (#1371), and what is left. Each task below carries its own
current-state summary, evidence, suggested approach and guardrails, so it can
be picked up without replaying the investigation.

Context chain, oldest first:

- [ADR 58](adr/0058-android-port.md) — the port itself, plus the on-device
  profiling trail in its Consequences updates (22 → 60fps title, map scenes
  2x, and what was measured after each fix).
- [app/android/README.md](../app/android/README.md) — the user-facing Frame
  rate section, kept in sync with every landed cut.
- [Profiling the engine](profiling.md) — how to measure a frame at all, and
  the desktop baseline.

Current device floor (C330, arm64-v8a): title/battle near 60fps, intro map
40-45fps, overworld ~26fps standing. What remains is split between the tasks
below and mruby game-logic speed (task 5).

## How to measure (read this before coding)

- **On device**: build and install per
  [app/android/README.md > Building](../app/android/README.md), push Nepheshel
  to the external-files dir, read the LVGL perf monitor (top-right,
  Android-only in `include/lv_conf.h`) and the engine log:
  `adb logcat -d -s RPG2K`. Record every number you claim in ADR 58's
  Consequences and the README Frame-rate list — that is the convention every
  previous cut followed.
- **On host**: the `--profile` repro at the top of
  [profiling.md](profiling.md), with `--profile_trace` for per-section
  aggregation. The host is far too fast to feel these wins end-to-end (its
  standing frame is ~0.7ms against a 16.67ms budget), so isolate the loop you
  changed with a `--script` microbench — see #1371's
  `blt_quads` grid benchmark for the shape of that.
- **Correctness**: this renderer has pixel-parity commitments
  (  [ADR 21](adr/0021-nepheshel-render-parity-under-wine.md)). Run
  `cmake --build build -t test` (mruby-rgss blt parity included),
  `ruby scripts/rpg2k_render_check.rb` and `ruby scripts/rpg2k_scene_check.rb`
  for anything touching composition or invalidation.

## 1. Verify #1371 on the device (small, do first)

#1371 made `blt_pixels` — the compose loop under `Bitmap#blt`/`#blt_quads`
(`mruby-rgss/src/lib.cxx`, "Row-copy fast path" comment) — row-`memcpy` fully
opaque rows and clip once up front. Host microbench: a 336-tile grid rebuild
through `#blt_quads` went ~0.6ms → ~0.02ms per pass (~30x); charset-shaped
blts ~4x from the hoisted clip alone. It has **not** been measured on the
device yet.

ADR 58 recorded the animation-step `map.layers` spikes at ~30-54ms after the
batching landed, and that spike is precisely this loop. Rebuild the APK from a
branch containing #1371, walk an autotile-heavy overworld, and record the
animation-step spikes and the map-scene fps deltas into ADR 58 + the README
Frame-rate list. If the spikes barely move, the residual is dispatch/mruby
overhead, not compose — that finding steers task 5.

## 2. Whole-area invalidation in `gfx_update` (in-repo, biggest remaining lever)

**State**: every bitmap mutation sets one boolean (`Bitmap::dirty`,
`mruby-rgss/src/lib.cxx` ~212-226). `gfx_update`'s dirty sweep
(`ProfilerScope("gfx.invalidate")`, ~3162-3180) calls `lv_obj_invalidate(obj)`
on the *whole sprite area* of any sprite whose bitmap is dirty. Both map-layer
sprites and the parallax sprite are screen-sized, so any single blit into them
— one event moving, one panorama strip — re-presents the entire display. This
is the same mechanism the style-setter fix removed for unchanged values
(~13ms); it still fires in full whenever a value genuinely changes.

**Why it is the lever**: on Android LVGL's accelerated backend renders draw
units directly into SDL textures
(`3rd/lvgl/src/drivers/sdl/lv_sdl_texture.c` — flush_cb only presents), so the
GPU redraw cost is exactly the invalidated area. Shrinking invalidation
shrinks the present. This is what ADR 58 means by "the scrolling present
path".

**Approach**: replace the bool with a dirty *rect* accumulated by every
mutation site (`blt`/`blt_quads`/`copy_blt`/`fill_rect`/`clear`/`stretch_blt`/
gradient fill/text drawing — grep `dirty = true` in lib.cxx; there are also
mutation paths outside Bitmap, e.g. the viewport snapshot at ~3238), clamped
to the sprite's on-screen area, and invalidate only that. Union across the
frame, sweep as today.

**Pitfalls**:

- The failure mode of an under-invalidated rect is *silence*: stale pixels
  with nothing raising. Enumerate mutation sites mechanically (grep), and
  consider a debug-mode escape hatch (e.g. force-full-invalidate flag) to
  bisect future bugs.
- A scrolled camera changes nearly every pixel anyway — this cut pays most on
  event-only frames and on whatever survives task 3's edge-strip compose, less
  on raw cross-map walks. Measure both shapes.
- Keep the change in-repo (`src/lib.cxx`). Patching the LVGL driver means
  moving a submodule pin; nothing above requires it.

## 3. Scroll-shifted layer recomposition (Ruby-side algorithmic cut)

**State**: `Scene::Map#draw_layers` (`mruby-rpg2k/mrblib/scene/map.rb`
~9799-9852) skips recomposition only when *nothing* moved, including the
sub-tile scroll remainder. Every sub-tile scroll step therefore clears both
layer buffers and `copy_blt`s the full cached grids into them (two ~336x256
ARGB8888 copies) before re-drawing events — per scroll frame.

**Approach**: the classic scroller cut — shift the previous frame's composed
buffer by the scroll delta (row-wise `memmove`; `Bitmap#copy_blt` already does
the carry-along clipping pattern) and compose only the newly exposed edge
strip (one tile column/row from the cache). Events then draw over the shifted
buffer as they do today.

**Pitfalls**:

- The equivalence "`copy_blt` onto a *cleared* destination equals `blt`"
  (documented above `bmp_copy_blt`, lib.cxx) is what makes the current
  compose correct. A shifted destination is *not* cleared — event compositing
  becomes true blend-over for one frame's worth of pixels. That is fine for
  opacity-255 sprites but changes semi-transparent edges unless the old
  content under them is first cleared to transparent in exactly the event's
  footprint. Think this through before writing code; it is the one subtle part
  of the task.
- The tile-cache validity rules (`tile_cache_valid?`, ~9903-9912) are the
  carefully-tuned part of this machinery — do not disturb them; this task only
  changes what happens *after* a valid-cache hit.
- Pixel-parity checks above must stay green; capture before/after frames on a
  scrolling route (`--no_render_wait` desync caveat in profiling.md).

## 4. Panorama re-tiling while walking

**State**: `Scene::Map#draw_parallax` (map.rb ~9724-9774) re-issues tiled
`copy_blt` strips across the screen every frame the camera moves (an
identical-frame skip exists but scrolling defeats it). Measured ~20ms on
device while walking a panorama map (app/android/README.md, Frame rate). Each
strip is already a fast row-copy since #1371, so the residual cost is the
number of dispatches, the full-screen byte movement, and — via task 2's
mechanism — a full-screen invalidate of the parallax sprite.

**Options, cheapest first**:

1. Batch the per-frame strips into one native dispatch — a `copy_blt_quads`
   analogous to #1364's `blt_quads` (same shape: array of
   `[qdx, qdy, sx, sy, w, h]`, fixed semantics, one `dst.dirty = true`).
   Removes dispatch overhead; the bytes still move.
2. Cache the *tiled* panorama once (one screen-plus-one-image surface) and
   translate the sprite position instead of re-blitting, wrapping at image
   edges. Removes the per-frame bytes entirely. More invasive: interacts with
   the half-rate/wrap formula (`Game::Parallax`, verified against EasyRPG in
   docs/TODO.md's parallax entries) and with the tone-carrying viewport every
   map sprite lives in. Prototype behind a flag if attempted.

Either way, pair with task 2 so the parallax sprite's invalidate follows the
actually-changed region.

## 5. mruby game-logic floor (context, no concrete cut yet)

After all graphics cuts, the standing-still frame's biggest block is
interpreter/event bookkeeping running inside mruby on the device CPU (ADR 58's
own conclusion). Allocation churn is the known amplifier — the tile-cache work
dropped it ~33x on host (profiling.md memory table) and similar wins may exist
in per-frame interpreter paths. Method: profile on host with
`--profile --profile_trace`, aggregate `scene.update` sub-sections, look for
per-frame allocations (`Rect.new`, arrays, string building) in
`mruby-rpg2k/mrblib/{interpreter.rb,game.rb,scene/map.rb}`. Only take this up
with a trace in hand; speculative mruby micro-optimisation has been wrong
before in this repo.

## Also Android-relevant: BGM-change hitch

Not steady-state fps, but visible on device the same as on desktop: every
`.mid` BGM/ME change blocks the game loop 20-30ms in `Mix_LoadMUS`
(profiling.md, "The part that is worth moving"). Unlike wasm/PSP/Wio, Android
has real threads, so the load-worker-thread sketch there can run
unconditionally on this target — keep `Mix_PlayMusic`/`Mix_PlayChannel` and
the chunk cache main-thread-owned per the constraints listed in profiling.md.

## Non-perf Android leftovers (already recorded elsewhere)

Kept as pointers rather than duplicated here:

- Quit leaves the process alive; relaunch dies on a second gflags parse —
  [app/android/README.md > Debugging on-device](../app/android/README.md).
- No in-app project picker/importer (adb push only), one ABI (`arm64-v8a`),
  MV/MZ does not render (EGL `eglGetPlatformDisplay` gap) —
  [app/android/README.md > Not yet wired](../app/android/README.md) and
  [ADR 58 > Decision](adr/0058-android-port.md).

## Ground rules for whichever task you pick

One logical change per branch/PR (`claude/<topic>-<suffix>`), changelog
fragment in `changelog.d/`, pre-commit clean, tests you touched actually run —
see AGENTS.md for the full flow. Engine-error convention: recover loudly, log
to stderr with the `[RPG2k]`/`[RGSS]` tag, never swallow. And the house rule
that has caught every bug in this trail: *measure the claim, diff the pixels,
and record both where the last person will find them* (ADR 58 + the README
Frame-rate list).
