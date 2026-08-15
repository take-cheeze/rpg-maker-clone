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

489 frames over 24.8s, `RelWithDebInfo` (the project default), 320x240,
software rendering under Xvfb. Percentages are of **CPU work**, not wall clock.

| section | calls | avg ms | max ms | % work |
| --- | ---: | ---: | ---: | ---: |
| `scene.update` | 490 | 25.93 | 537.22 | 76.1% |
| ` map.render` | 489 | 23.63 | 50.52 | 69.2% |
| ` map.layers` | 490 | **22.66** | 49.56 | **66.5%** |
| `gfx.lvgl` | 489 | 7.94 | 34.27 | 23.3% |
| ` map.pictures` | 490 | 0.78 | 1.13 | 2.3% |
| ` map.refresh_pages` | 489 | 0.10 | 0.23 | 0.3% |
| `audio.music_load` | 1 | 29.61 | 29.61 | 0.2% |
| `input.update` | 490 | 0.05 | 0.12 | 0.2% |
| ` map.overlay` | 490 | 0.05 | 0.11 | 0.1% |
| ` map.chars` | 490 | 0.02 | 0.05 | 0.1% |
| `gfx.invalidate` | 489 | 0.02 | 0.06 | 0.1% |
| ` map.animate_events` | 489 | 0.01 | 0.08 | 0.0% |
| ` map.animation` | 490 | 0.004 | 0.03 | 0.0% |
| ` map.parallax` | 490 | 0.003 | 0.03 | 0.0% |
| `audio.sample_load` | 1 | 0.60 | 0.60 | 0.0% |
| `audio.resolve` | 2 | 0.20 | 0.20 | 0.0% |
| `audio.update` | 490 | 0.0002 | 0.0004 | 0.0% |

Headline: **34.1ms of work per frame against a 16.67ms budget** — 2x over, so
the run sits at 20fps with every frame counted as a drop. Allocation churn is
~350,000 mruby allocations/second.

Note that `map.layers` and `map.chars` are inside the `if @battle_ui` gate in
`#render`, so they stop being recorded during a fight — the map is not drawn
there at all. A profile of a battle-heavy run will show a different shape.

### The bottleneck is `map.layers`

Two thirds of the frame is one loop, `Scene::Map#draw_layers`. Every frame it
clears both chip-layer bitmaps and re-blits the whole visible grid — 21x16 =
336 tiles, each up to two layers, each tile going through
`Game::ChipsetLayout.quads`, which returns a freshly allocated array (four
8x8 quarters for an autotile) that is then blitted quad by quad.

Nothing about that is conditional. The map is redrawn from scratch whether or
not the camera moved, whether or not any tile animated, and whether or not
anything on screen changed at all. That is also where the allocation churn
comes from: `quads` is a pure function of `(id, abf, cf)` and is called
~670 times per frame, allocating every time.

Two independent things are therefore being paid for every frame:

1. **Recomputing tile geometry** that depends only on `(id, abf, cf)`.
2. **Re-blitting static scenery** that did not change since the last frame.

(1) is the cheaper fix and was measured as a one-off experiment (against a
baseline reading 22.3ms / 33.5ms, a hair under the table above): memoizing
`quads` on `(id, abf, cf)` took `map.layers` from 22.3ms to 12.9ms and frame
work from 33.5ms to 22.8ms (20.0 -> 25.4fps), with allocation churn dropping
from ~350k to ~225k/s. That is a
~30% frame-time win from a cache, and it is *not* committed here — this page
records the measurement, not the change. Note the guard it needs: `quads` is
called with `nil` ids, so a naive key computation raises.

(1) alone does not reach 60fps — 22.8ms is still over budget, and the residual
12.9ms is the per-tile blit loop itself. Getting under 16.67ms means attacking
(2): cache the composed layer and redraw only on camera movement or an actual
animation step, or move the inner loop out of mruby.

`gfx.lvgl` (7.7ms, the LVGL render and flush) is the second cost and is
largely a consequence of the first — the full-surface invalidation that a
from-scratch tile redraw implies.

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
already elsewhere, and would buy ~0.0002ms/frame. It is not where the 34.1ms
goes.

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
