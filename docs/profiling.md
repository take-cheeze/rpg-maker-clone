# Profiling the engine

How to measure where a frame goes, and what the measurement currently says.
The profiler itself (flags, summary-line format, Chrome trace export) is
documented in [README.md](../README.md#profiling); this page is the
*findings* — a recorded baseline to compare against, and the reasoning that
baseline supports.

## Reproducing the baseline

```sh
scripts/native-build-without-nix.bash    # or: nix develop, cmake --build build

SDL_AUDIODRIVER=dummy \
  ./scripts/quiet_alsa.bash xvfb-run -a ./build/rpg_maker_clone \
  --test_play --profile --profile_interval_ms=1000 \
  --profile_trace=trace.json --timeout_ms=25000 \
  --game_dir data/Nepheshel206beta/Nepheshel206Rbeta --rpg2k_new_game
```

`--rpg2k_new_game` is what pushes the run past the title into the map, which
is the only scene worth profiling — the title screen draws almost nothing.

Read the summary lines off stderr, or aggregate the whole run from the trace.
The trace is the better source: the stderr line only prints the **top eight**
sections, so the cheap ones (the whole audio path, among others) fall off the
end and look absent when they are merely small. Each `frame` event in the
trace carries the frame's `work_ms`, which is the right denominator — dividing
by wall-clock instead folds in the fps-cap sleep and understates every section.

## Baseline: RPG2000 / Nepheshel, map scene

1405 frames over 24.8s, `RelWithDebInfo` (the project default), 320x240,
software rendering under Xvfb. Percentages are of **CPU work**, not wall clock.

| section | calls | avg ms | max ms | % work |
| --- | ---: | ---: | ---: | ---: |
| `scene.update` | 1406 | 4.69 | 536.65 | 54.0% |
| `gfx.lvgl` | 1405 | 3.75 | 15.39 | 43.2% |
| ` map.render` | 1405 | 3.16 | 21.83 | 36.4% |
| ` map.layers` | 1406 | 2.25 | 20.84 | 26.0% |
| ` map.pictures` | 1406 | 0.76 | 0.96 | 8.7% |
| ` map.refresh_pages` | 1405 | 0.09 | 0.34 | 1.0% |
| `input.update` | 1406 | 0.05 | 0.21 | 0.6% |
| ` map.overlay` | 1406 | 0.04 | 0.29 | 0.4% |
| `audio.music_load` | 1 | 32.64 | 32.64 | 0.3% |
| ` map.chars` | 1406 | 0.02 | 0.12 | 0.2% |
| `gfx.invalidate` | 1405 | 0.02 | 0.10 | 0.2% |
| ` map.animate_events` | 1405 | 0.01 | 0.09 | 0.1% |
| `audio.update` | 1406 | 0.0002 | 0.0004 | 0.0% |

Headline: **8.7ms of work per frame against a 16.67ms budget**, running at
57fps. Allocation churn is ~30,000 mruby allocations/second.

This is the state *after* the map-layer work described below. The same run
before it sat at **20fps and 34.1ms a frame** — over budget on every single
frame — with `map.layers` alone at 22.7ms (66.5% of work) and ~350,000
allocations/second. Those are the numbers the rest of this page reasons about,
and they are what the tile cache and `Bitmap#copy_blt` removed.

Note that `map.layers` and `map.chars` are inside the `if @battle` gate in
`#render`, so they stop being recorded during a fight — the map is not drawn
there at all. A profile of a battle-heavy run will show a different shape.

### What `map.layers` used to cost, and why

Two thirds of the frame was one loop, `Scene::Map#draw_layers`. Every frame it
cleared both chip-layer bitmaps and re-blitted the whole visible grid — 21x16 =
336 tiles, each up to two layers, each tile going through
`Game::ChipsetLayout.quads`, which returned a freshly allocated array (four
8x8 quarters for an autotile) that was then blitted quad by quad.

Nothing about that was conditional. The map was redrawn from scratch whether or
not the camera moved, whether or not any tile animated, and whether or not
anything on screen changed at all. That was also where the allocation churn
came from: `quads` is a pure function of `(id, abf, cf)` and was called ~670
times per frame, allocating every time.

So two independent things were being paid for on every frame:

1. **Recomputing tile geometry** that depends only on `(id, abf, cf)`.
2. **Re-blitting static scenery** that did not change since the last frame.

Both are now avoided.

**(1) `quads` is memoised** on `(id, abf, cf)`. Alone this took `map.layers`
from 22.3ms to 12.9ms and frame work from 33.5ms to 22.8ms (20 → 25fps), with
allocation churn dropping from ~350k to ~225k/s. Two things it needs, both of
which bit during development: `quads` is called with `nil` ids (the renderer
draws the map edge every frame), and the key has to stay inside a signed
32-bit `mrb_int` or it becomes a bignum on the Emscripten / PSP / Wio builds.
Resolving the tile's block first answers both.

**(2) The grid is cached.** `#rebuild_tile_cache` builds the visible tiles into
a pair of buffers on whole-tile boundaries, and each frame `#draw_layers` copies
those into the frame buffers at the sub-tile scroll offset. The rebuild only
re-runs when `#tile_cache_valid?` says something it depends on changed: the
camera crossing a tile, an animation input *the visible tiles actually follow*,
a Tile Substitution (via `Game::Map#revision`), a tileset swap, or a new map.
The events cannot be cached — they move every frame and composite into these
same buffers — which is why the cache is separate from the frame buffers rather
than being drawn to directly.

That last qualifier matters more than it looks. `Game::ChipsetLayout.anim_c`
steps every 6 frames but only drives the block C animated chips; keying the
cache on it unconditionally rebuilt 18% of frames instead of 4%, for an input
most maps have nothing on screen that reads. `.anim_input` is what tells the
two apart.

**The per-frame copy then became the cost.** Through `#blt` those two
336x256 copies measured ~5ms a frame — a third of the whole budget spent
alpha-blending onto a surface that had just been cleared. `Bitmap#copy_blt`
does the same job as a row-wise `memcpy`, taking the copy path to ~1.8ms.

**(3) The upper layer's blank chip is not drawn.** RPG2000's first upper-layer
id (`BLOCK_F`) means "nothing here", and real data is very nearly all of it —
98.45% of the 584,049 upper cells across Nepheshel's 543 maps — so a rebuild
was blitting a fully transparent chipset cell ~330 times for no pixels. That
is 28% of a rebuild (16.5ms → 11.8ms), which matters more than its share of
the average suggests: the rebuild is the spike that drops frames. Note it is a
*drawing* sentinel only — the blank id still indexes entry 0 of the chipset's
upper passability table, a real lookup, so `ChipsetLayout.upper_blank?` must
never be used to skip one.

Net: `map.layers` 22.7ms → 2.3ms, frame work 34.1ms → 8.7ms, 20fps → 57fps,
and 96% of frames now skip the rebuild entirely.

`gfx.lvgl` (3.8ms, the LVGL render and flush) is now the largest single cost
after `map.layers`. It has not changed in absolute terms — the layer surfaces
are still fully invalidated every frame, because the events drawn over them
change every frame.

#### What it costs in memory

Caching trades memory for time, so the trade was measured rather than assumed.
Two things are newly allocated:

- **The two cached grids**, `COLS*TILE x ROWS*TILE` at ARGB8888 — 336x256x4 =
  336 KiB each, **672 KiB** together. Fixed, allocated once with the scene.
- **The `quads` table.** Bounded, not unbounded: its key space is the game's
  distinct tile ids x 3 `abf` x 4 `cf`. For Nepheshel that ceiling is 639
  distinct ids across all 543 maps, so **7,668 entries / ~28,000 small arrays /
  ~2.7 MiB** (measured under CRuby, whose objects are larger than mruby's) —
  and only if a session renders every tile in the game in every animation
  state. It cannot grow with play time past that.

Against that, the change removes ~97% of the engine's allocation churn, which
is worth more than the caches cost. Two 3-minute runs, same game, both read at
their RSS plateau:

| | before | after |
| --- | ---: | ---: |
| process RSS (plateau) | 70.02 MB | **69.33 MB** |
| LVGL pool, floor (retained) | 16.60 MB | 16.58 MB |
| LVGL pool, peak | 26.72 MB | 25.70 MB |
| mruby live blocks, floor | 21,806 | 21,132 |
| mruby live blocks, peak | 190,539 | 162,916 |
| allocations/second | 348,172 | **10,571** |

So there is **no net memory cost** — RSS came out 0.7 MB *lower*, and every
other figure is flat or down. The 672 KiB of surfaces and whatever the quads
table has filled are more than paid for by the garbage no longer being
produced: with 33x fewer allocations the heap holds far less transient rubbish
between collections (peak live blocks down 27,000).

Read short windows carefully here. A 40-second sample of the same pair showed
the *optimized* build with a higher heap peak, purely because the two builds
were caught in different phases of the GC's sawtooth; only at the plateau do
the numbers mean anything.

#### Checking it still draws the same thing

This is a renderer with pixel-parity commitments (ADR 0021), so the change was
diffed rather than argued. Two mechanical facts carry it:

- The coordinate mapping is unchanged. Taking the source from `(ox, oy)` maps
  cache pixel `rx*TILE + i` to destination `rx*TILE + i - ox`, which is exactly
  where the old per-tile loop drew it, and both ends clip the same way.
- `#copy_blt` onto a cleared destination equals `#blt` onto one, because
  `blend_over` against a fully transparent pixel returns the source unchanged.
  The mruby-rgss tests assert this over every alpha. The one genuine difference
  is invisible and worth knowing about: for a *fully transparent* source pixel
  `#blt` bails out and leaves cleared black where `#copy_blt` copies the colour
  channels across. Nothing can observe it — a `da == 0` pixel contributes
  nothing to any later composite and does not render — but a byte-for-byte
  comparison of the two buffers would show it.

End to end, frames were captured from a build before and after the change,
driven to the same input-gated point in Nepheshel's opening (`--no_render_wait`
so the frame-driven waits do not desynchronise two builds running at different
frame rates). **The map region is pixel-identical — zero differing pixels over
640x435**, tile layers, autotiles, furniture and character sprites included.
Skipping the blank upper chip was diffed the same way and came out identical
over the *whole* frame, which is the direct evidence that the chip it stopped
drawing really was fully transparent rather than merely assumed to be.

`scripts/rpg2k_scene_check.rb` covers the behaviour directly: a frame that
changed nothing must not re-blit a single tile; a tile crossing, a Tile
Substitution and an animation step the visible tiles follow must each rebuild;
and a map whose upper layer is entirely the blank id must cost exactly its
lower layer while still answering passability through that id.

Worth repeating for anyone extending this: the failure mode of a render cache
is silence. Too eager and it only costs speed, but too lazy and the picture is
simply wrong, with nothing raising. The invalidation checks are the part of
this work most worth keeping honest.

## Audio: what is already off the main thread

Short version: **the audio *processing* is already on another thread, and it
was never the bottleneck.** SDL_mixer decodes, synthesises and mixes on the
audio device thread that `Mix_OpenAudio` starts. Observed directly by counting
`/proc/self/task` around the call:

| point | threads |
| --- | --- |
| before `Mix_OpenAudio` | 1 (`main`) |
| after `Mix_OpenAudio` | 2 (`+ SDLAudioP2`) |
| while a `.mid` plays | 5 (`+ 3` TiMidity/decoder workers) |

What genuinely runs on the game-loop thread is only the *control* surface, and
the profile prices it at essentially nothing:

- `audio.update` — the per-frame backend poll (`Mix_PlayingMusic`, to resume a
  BGM after an ME): **0.0002ms/frame**, 0.1ms total across a 25s run.
- `audio.resolve` — the Ruby asset search in `RGSS::Audio.resolve`: 0.23ms,
  and only on an actual Play command.
- `Mix_PlayMusic` / `Mix_PlayChannel`: 0.02ms.

So moving "audio processing" to a worker thread would move work that is
already elsewhere, and would buy ~0.0002ms/frame. It was never where the frame
went — not at the 34.1ms this page originally measured, and still not at 8.7ms.

### The part that *is* worth moving: asset load

One audio call does block the game loop, and it is the load, not the playback.
Measured against Nepheshel's own files (SDL2\_mixer 2.x, FreePats patch set):

| call | cost on the calling thread |
| --- | ---: |
| `Mix_LoadMUS` on a `.mid` | **20–30ms** |
| `Mix_LoadMUS` on a `.wav` | 0.05ms |
| `Mix_PlayMusic` | 0.02ms |
| `Mix_LoadWAV` (SE, first play) | 0.66ms |

A MIDI load is a 1–2 frame hitch, and Nepheshel is 143 `.mid` tracks, so every
BGM/ME change pays it — including every ME, which reloads the interrupted BGM
when it finishes (`maybe_resume_bgm`). SE are cached after first decode
(`g_chunks`), so they cost 0.66ms once per distinct sample and nothing after.

This is a real, if narrow, target: a load/decode worker thread that hands the
finished `Mix_Music`/`Mix_Chunk` back to the main thread to start. It removes a
visible stutter on BGM change. It does **not** improve steady-state frame rate,
because there is no steady-state audio cost to remove.

Note this is the same class of bug already fixed once here: `Mix_GetMusicPosition`
costs *hundreds* of ms per call on the MIDI decoder, and polling it every frame
for the "BGM played once" check once dragged this same game to under 2fps. It
is now answered from the clock instead (see `g_music_start_ms` in
`src/sdl_audio.cxx`). The lesson generalises — on this backend the expensive
audio calls are the ones that touch the decoder, not the ones that mix.

### Constraints on any audio threading work

- **The browser build is single-threaded.** The Emscripten link options in
  `CMakeLists.txt` carry no `-pthread` / `-sUSE_PTHREADS`, and pthreads in wasm
  additionally need `SharedArrayBuffer`, i.e. COOP/COEP headers on the deployed
  page. Since GitHub Pages is the primary distribution, a worker thread has to
  be conditional, with the synchronous path kept for wasm.
- **PSP and Wio have no usable `std::thread`.** `mruby-rgss/src/terminal.cxx`
  already documents and handles exactly this: its background writer thread is
  compiled out with `#if !defined(PSP_BUILD) && !defined(WIO_TERMINAL)`. Any
  audio worker should follow that same shape.
- **SDL_mixer's own API is not thread-safe across arbitrary calls.** The load
  can move; `Mix_PlayMusic`/`Mix_PlayChannel` and the `g_chunks` cache should
  stay owned by one thread.

## Caveats on these numbers

- Software rendering under Xvfb with `SDL_AUDIODRIVER=dummy`. Absolute
  milliseconds will differ on real hardware; the *ratios* are what to compare.
- `--profile` and friends are test-play-only. Without `--test_play` (or
  `Game.ini` `[Game] Test=1`) the flags are parsed and then ignored, and the
  run prints no profiler output at all.
- The stderr summary caps at eight sections. Prefer the trace when you care
  about anything cheap.
- One game, one scene. The RPG XP / VX / MV runtimes have their own scene
  code and are not covered by this baseline.
