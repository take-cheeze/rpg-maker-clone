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

### WASM: the frame-pacing sleep was blocking audio, not the decoder

Everything measured above used `SDL_AUDIODRIVER=dummy` on the native build,
where "the audio thread" is a real OS thread SDL_mixer owns outright. That
does not hold in the browser: with no `-pthread`/`-sUSE_PTHREADS` and no
`-sAUDIO_WORKLET` (`CMakeLists.txt`'s `if(EMSCRIPTEN)` block never sets
either), Emscripten's SDL2 port falls back to a ScriptProcessorNode, whose
callback the Web Audio spec requires to run on the **main thread** — the same
one `emscripten_set_main_loop` drives the whole game loop on.

`Graphics.update`'s frame-pacing block (`mruby-rgss/src/lib.cxx`, `gfx_update`)
used to enforce 60fps with a real blocking wait — `lv_delay_ms`, backed by a
plain OS sleep/spin — every single frame, sized to whatever was left of the
16-17ms budget. On desktop that costs nothing but wall clock; in the browser
it synchronously froze the one thread the audio callback also needed, which
is a textbook cause of audible delay/glitching that has nothing to do with
decode cost. It was also worse than it needed to be on a >60Hz display:
`emscripten_set_main_loop(main_loop, 0, 0)` used `requestAnimationFrame`,
which calls back at the display's own refresh rate, so a 120Hz/144Hz screen
ran the whole block — including this sleep — more often than the 60fps game
logic wanted.

The fix keeps the 60fps cap but stops enforcing it with a blocking call under
Emscripten: `emscripten_set_main_loop(main_loop, 60, 0)` (`src/main.cxx`) asks
Emscripten to pace the calls itself via its `setTimeout`-based scheduling
instead of raw vsync, which yields back to the browser's event loop between
frames instead of occupying it — and `gfx_update`'s own `lv_delay_ms` call is
`#ifndef __EMSCRIPTEN__`, so the deadline/carry-forward bookkeeping that keeps
frame timing accurate still runs, but nothing blocks the JS thread on top of
Emscripten's own (already non-blocking) pacing.

#### The buffer: sized for resilience, not baseline latency

The first pass here shrank `Mix_OpenAudio`'s buffer for `__EMSCRIPTEN__`
(2048 → 1024 samples) on the theory that, with the blocking sleep gone, a
smaller buffer would just mean less baseline round-trip latency. That is
backwards for this backend, and the buffer is now larger instead (2048 →
4096): ScriptProcessorNode's callback has a well-documented failure mode
where, if the main thread does not hand it the next buffer in time, it does
not drop the missed buffer and resync to the clock -- it fires late and
*stays* that late, and the lateness compounds on every further stall until
the page reloads (this is one of the reasons the API is deprecated in favour
of AudioWorklet; see the Chromium/Firefox/spec discussion linked from
[MDN's AudioWorklet guide](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API/Using_AudioWorklet)
and [WebAudio/web-audio-api#253](https://github.com/WebAudio/web-audio-api/issues/253)).
A smaller buffer gives the main thread *less* slack before a given stall
crosses that line, not more.

**Holding a movement key is close to the worst case for this**, reported
directly as "significant audio delay on key press hold" after the pacing fix
above shipped: it is *sustained* main-thread cost rather than one spike --
every one of those frames pays the ordinary camera/animation/collision work,
and periodically also the tile-crossing cache rebuild (the multi-millisecond
spike documented earlier on this page) -- so it is repeated, compounding
chances to miss the deadline, and several seconds of held input can build up
a delay far more noticeable than a few extra milliseconds of fixed latency
would be. A bigger buffer cannot make any one stall shorter, but it makes a
given stall much less likely to actually cross the deadline in the first
place, which is the only lever available without a real audio thread to
mix on.

**A real fix would still be AUDIO_WORKLET**, which runs the audio callback on
its own thread outside the main JS thread entirely and would remove this
failure mode rather than just making it less likely. That was not attempted
here: it needs Wasm Workers, and SDL2's own Emscripten port does not
currently build with `-sWASM_WORKERS`/`-pthread` at all --
[emscripten-core/emscripten#19667](https://github.com/emscripten-core/emscripten/issues/19667)
tracks `SDL_atomic.c.o` failing to link because the vendored SDL2 build
lacks the `atomics`/`bulk-memory` target features either path requires. Worth
revisiting if the buffer bump above turns out not to be enough in practice,
but it is a real architectural change (a different SDL2 build, and this
engine's own single-threaded assumptions reaching across a worker boundary)
that deserves its own investigation and ADR rather than a speculative
attempt with no way to test it against a real browser from this repo's CI.

This whole section is reasoning from how the browser's audio and event-loop
model works, not a browser-measured profile — the caveat below about this
page's numbers being native/Xvfb-only applies doubly here, since none of it
was ever measured against real Web Audio callback timing. If audio in the
browser is still audibly delayed after this, that measurement -- ideally
captured while holding a direction key, the case that surfaced this -- is
the next thing to get, not another guess from the native numbers above.

#### Scene transitions: a much bigger stall than anything the buffer bump covers

Reported next, after the pacing and buffer fixes above: audio still glitches
on a scene transition (walking onto a map-exit tile). This is not the same
bug wearing a different hat -- it is the same underlying constraint (a stall
on the single JS thread starves whatever ScriptProcessorNode callback is
due, and per the buffer discussion above that lateness does not resync on
its own) hitting a stall an order of magnitude larger than anything a buffer
sized for per-frame jitter can absorb.

A map-to-map transition (`Scene::Map#perform_teleport`,
`mruby-rpg2k/mrblib/scene/map.rb`) runs as **one synchronous block inside a
single `scene.update` frame** -- nothing about it is spread across frames.
In order: the destination `.lmu` is parsed fresh (`RPG2k#load_map`), the map's
BGM is resolved and started if it changed (`play_map_bgm` -- a `.mid` change
alone costs the 20-30ms `Mix_LoadMUS` figure from earlier on this page), the
destination's chipset graphic is decoded (`load_chipset_graphic`, skipped
only when the tileset id happens to be unchanged), and every one of the
destination map's events and Common/map Parallel Processes is rebuilt
(`build_events`, `build_parallels`). None of this had its own profiler
section before now -- it was invisible inside the umbrella `scene.update`
bar. It does now: `map.transition.load`, `map.transition.bgm`,
`map.transition.chipset`, `map.transition.build_events` and
`map.transition.build_parallels`, at both call sites (`Scene::Map#initialize`
for a fresh map entry/Continue, and `#perform_teleport` for an in-session
Transfer Player/Teleport/Recall to Location).

The baseline table at the top of this page already has the relevant number,
uncommented on until now: `scene.update`'s **536.65ms max**, 114x its own
4.69ms average, on a 1405-frame run that is a single continuous
`--rpg2k_new_game` session -- i.e. one frame paid for something the rest did
not. Nepheshel's own opening is a long camera pan that ends in exactly one
Teleport into the first room (`perform_teleport`'s comments describe this
same sequence twice), which is consistent with this outlier being that
transition. 536ms is **~5.75x** the ~93ms of slack the 4096-sample wasm audio
buffer provides, on hardware faster than a browser's wasm execution -- nowhere
close to survivable by sizing a buffer, which is the only lever the fix above
had available.

**Not fixed here.** Unlike the frame-pacing and buffer work above, closing
this gap means either making the transition itself faster (the four new
sections above finally make it possible to find out which of load/chipset
decode/event-build actually dominates, rather than guessing) or spreading it
across several frames behind the fade so no single one blocks the thread for
that long -- both real engine changes, not a config tweak, and neither
should be attempted blind the way the frame-pacing fix's first pass already
had to be corrected twice. Reordering `play_map_bgm` to run after the heavy
work instead of before was considered and deliberately not done: the stall
itself is what starves the audio callback regardless of which track is
nominally playing, so moving the BGM call only changes which track's
in-flight audio gets cut and does not shorten the stall -- indeed it risks
being worse, briefly resuming the *old* track for a few audio callbacks right
before cutting to the new one, versus the current clean silence-then-new-track
result. The right next step is measuring with the new sections against a
save positioned right before a map exit, then deciding what to shorten or
defer from real numbers, the same way `map.layers` was fixed earlier on this
page.

## Per-frame object allocation

Separate from frame *time*: how many mruby objects the map scene allocates
each frame, tracked because a string of fixes (skip_to's terminator arrays
hoisted to frozen constants; `Scene::Map#events_dirty?`/
`#record_map_event_positions` reusing Arrays instead of rebuilding them every
frame; `#step_parallels` and four other `@events.each` loops rewritten as
block-free `while` loops; `Game::Interpreter#range` returning a `Range`
instead of a throwaway Array; `Array#include?` given a native-equivalent
override because mruby's own falls through to a block-allocating
`Enumerable#include?`) cut it by well over half across several rounds — see
`changelog.d/` for each one's own measurement.

Measured the same way as the time baseline above (same command, same
Nepheshel run), reading `RGSS::Profiler.stats[:object_types]`'s cumulative
`:allocs` per type at two points in a steady window rather than the summary
line's live counts (those rise and fall with GC and cannot answer "how many
were allocated between two points"):

| type | allocs/sec |
| --- | ---: |
| `Array` | ~4000 |
| `Proc` | ~1650 |
| `env` | ~985 |

`scripts/rpg2k_alloc_regression_check.rb` automates exactly this measurement
(via the profiler trace's `mruby_type_allocs` counter series, see
[README.md](../README.md#profiling)) and fails if any of the three exceeds a
ceiling set from this table — the standing regression guard for the fixes
above, run in CI alongside the other RPG2000 boot smokes. Re-run it with
`--report` to see fresh rates without asserting, e.g. after a deliberate new
per-frame feature that genuinely needs to raise a ceiling (with a comment in
the script saying why), or while investigating whether a change regressed one.

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
