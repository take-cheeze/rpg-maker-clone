# 4. Built-in CPU/memory profiler

Date: 2026-07-24

## Status

Accepted

## Context

The runtime targets a 60 Hz frame budget (16.6ms) and is intended to run on
modest hardware, including embedded boards. As the map scene, event interpreter
and RGSS display objects grew, "is a frame too slow, and where does the time
go?" became a recurring question with no first-class answer. The terminal
backends already draw an *emit-rate* overlay (`--term_stats`), but that measures
terminal I/O throughput, not the CPU cost of building a frame, and it is only
present when a terminal backend is active.

We wanted a way to attribute per-frame time to the loop's phases
(`scene.update`, `input.update`, and the sub-steps of `Graphics.update`) and to
watch memory pressure (process RSS, the LVGL heap pool, and mruby allocation
churn) — without adding an always-on cost to the shipped runtime, and without
pulling in a heavyweight external profiler that cannot follow the code across
the C++/mruby boundary or into the Emscripten build.

Constraints that shaped the design:

- **The frame boundary lives in Ruby.** One `main_loop` iteration renders
  exactly one frame (`Graphics.update` is called once), so the natural frame
  span is the Ruby iteration, not the C++ `gfx_update` call.
- **The fps-cap sleep lives in C++.** `gfx_update` sleeps away the rest of the
  16.6ms budget with `lv_delay_ms`, so a naive whole-iteration timer would
  report mostly sleep.
- **Memory accounting must stay portable.** mruby's allocator hook does not hand
  back the previous size on realloc/free, and stashing a size header would break
  the 8-byte alignment mruby's word boxing depends on (already a known hazard on
  wasm32).

## Decision

Add a small, self-contained profiler (`include/profiler.hxx`,
`mruby-rgss/src/profiler.cxx`), enabled with `--profile`
(`--profile_interval_ms` tunes the report cadence) and inert otherwise.

- **Frame span from Ruby, work excludes idle.** `RGSS::Profiler.frame` wraps
  `main_loop`; `gfx_update` reports its cap sleep through
  `profiler_note_idle`, so the reported per-frame *work* is `span - idle`, i.e.
  CPU cost. fps is derived from the measured frame period.
- **Named sections.** A `ProfilerScope` RAII helper times C++ blocks (the
  `gfx.*` phases), and `RGSS::Profiler.section("name") { ... }` times Ruby
  blocks (`scene.update`, `input.update`, and anything game code wants to add).
  Sections aggregate call count, total/avg/max time and share of frame work.
- **Memory probes.** Process RSS from `/proc/self/statm` (Linux), the LVGL heap
  pool via `lv_mem_monitor` (guarded by `lv_is_initialized` so it is safe before
  a display exists — e.g. in the unit-test binary), and mruby allocation
  activity via a thin allocator wrapper (`profiler_allocf`) that counts live
  blocks and cumulative allocations while forwarding every call unchanged. The
  wrapper tracks only call shape, never sizes, so alignment is untouched.
- **Reporting.** Once per interval a single summary line is written to stderr
  (matching the direct-`stderr` convention the terminal stats path already
  uses, so the gem needs no ng-log dependency). `RGSS::Profiler.stats` exposes
  the same numbers as a Hash for tests and ad-hoc measurement.

The subsystem is gated so a build without `--profile` pays only one predicted
branch per frame and per section.

## Consequences

- Frame-time bottlenecks can be attributed to concrete phases from a normal run,
  including under the terminal and (for the timing half) Emscripten builds.
- The "work vs sleep" split makes the CPU figure meaningful even though the loop
  deliberately idles most of each frame.
- The allocation counters require the native build's custom allocator; the
  Emscripten build opens mruby with the default allocator (for alignment
  reasons documented in `main.cxx`), so `live_blocks`/`allocs/s` read zero
  there. RSS is likewise Linux-only. These are reported as-is rather than
  faked.
- Instrumentation lives at the loop's seams (`main_loop`, `gfx_update`); new hot
  paths need a `section`/`ProfilerScope` added to show up in the breakdown.
- A machine-readable **Chrome trace** export (`--profile_trace=FILE`, or
  `RGSS::Profiler.trace_start`/`trace_stop`) reuses the same instrumentation:
  each frame and section becomes a Chrome Trace Event `X` (complete) event on a
  shared thread track — nesting into a flame chart in `chrome://tracing` /
  Perfetto — and each memory sample becomes `C` (counter) events. It is streamed
  to disk (comma-prefixed events, flushed per interval, closed in
  `gem_final`); the format's tolerance of a missing closing bracket keeps a
  crash- or `Ctrl-C`-truncated trace loadable. This gives the per-frame timeline
  the periodic stderr summary cannot.
- The profiler does not yet render an on-screen overlay; that remains a possible
  follow-up (it would reuse the terminal stats row).
