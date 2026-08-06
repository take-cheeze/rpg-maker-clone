# RPG Maker Clone project

## Scope of this project
- Provide RPG Maker compatible game runtime to run on any environment such like embedded boards
- Current target is to run game Nepheshel which is built by RPG Maker 2000
- Also by using mruby, the support of `RPG Maker XP/VX/VX Ace` which have RGSS will be easier
- For further support of RPG Maker version we need JavaScript support of game engine

## Features

### Title Screen
- Displays the title image from the game's data
- Shows a menu with options for New Game, Continue, and Shutdown
- Supports keyboard navigation (up/down) and selection (enter/Z)
- Menu items are drawn using the game's font system
- Selection is highlighted with a cursor

### Terminal gaming (sixel / iTerm2)
- Alternative display backends that render each frame to the terminal instead of
  opening a window: the DEC sixel protocol (`--sixel`) and iTerm2's inline-image
  protocol (`--iterm`)
- Lets the runtime be played on hosts without a windowing system (headless
  servers, SSH sessions, embedded boards with a serial console); `--iterm` also
  covers terminals that lack sixel support, notably VS Code's integrated
  terminal
- Both backends share the same windowless terminal core
  (`mruby-rgss/src/terminal.cxx`: raw-mode input, monotonic tick/delay source,
  alternate-screen handling) and differ only in the frame encoder
  (`sixel.cxx` / `iterm.cxx`)
  `RGSS::Input`. Key reference:

  | Key(s)                    | `RGSS::Input` action |
  | ------------------------- | -------------------- |
  | `↑` / `W`                 | `UP`                 |
  | `↓` / `S`                 | `DOWN`               |
  | `←` / `A`                 | `LEFT`               |
  | `→` / `D`                 | `RIGHT`              |
  | `Z` / `Enter` / `Space`   | `C` (confirm)        |
  | `X` / `Esc`               | `B` (cancel)         |
  | `C`                       | `A`                  |
  | `Q` / `Ctrl-C`            | quit the runtime     |

  The same reference is drawn as a one-line legend on the top row of the
  terminal, just above the game image (on both backends), so the controls are
  always visible while playing.

  Terminals do not report key-release events, so a key is treated as held for
  a short window (`HOLD_MS`) after its last byte; the terminal's own
  auto-repeat sustains movement while a key stays down.
- Draws an emit-rate report (frame size, MB/s, fps) on-screen just under the
  control legend, refreshed about once a second, so the real per-frame byte cost
  is visible while playing; on by default, disabled with `--noterm_stats`
- Output is throughput-bound: the sixel path for 320×240 at 60 Hz needs roughly
  20 Mbaud (up to ~70 Mbaud worst case); the iTerm2 path PNG-compresses each
  frame, which shrinks flat tile/sprite regions substantially but spends CPU on
  encoding. Either way the backend targets a local PTY or SSH pipe, not a real
  serial UART
- See `docs/adr/0001-terminal-gaming-sixel.md` and
  `docs/adr/0003-terminal-gaming-iterm2.md` for the design rationale and a full
  bandwidth breakdown

### Profiling (`--profile`)
- A built-in CPU/memory profiler for locating frame-time bottlenecks, off by
  default and enabled with `--profile` (report cadence via
  `--profile_interval_ms`, default 1000ms)
- Implemented in `mruby-rgss/src/profiler.cxx` behind `include/profiler.hxx`.
  The whole subsystem is inert until enabled, so the default build pays only a
  single predicted branch per frame and per section
- Frame timing: the game loop is one `Graphics.update` per iteration, so the
  frame is bounded from Ruby by `RGSS::Profiler.frame` around `main_loop`.
  `Graphics.update` reports its fps-cap sleep via `profiler_note_idle`, so the
  reported per-frame **work** figure is CPU cost, not time spent sleeping
- Sub-section timing: `scene.update` and `input.update` are wrapped in
  `main_loop`, and the `gfx.*` phases (z-ordering, bitmap invalidation, LVGL
  handling) are wrapped inside `gfx_update` with the `ProfilerScope` RAII
  helper. Any Ruby code can add its own with
  `RGSS::Profiler.section("name") { ... }`
- Memory sampling: process RSS (from `/proc/self/statm` on Linux), the LVGL
  heap pool via `lv_mem_monitor` (guarded by `lv_is_initialized`), and mruby
  allocation activity — the native build routes mruby's allocator through
  `profiler_allocf` to count live blocks and allocation churn (the Emscripten
  build opens mruby without a custom allocator, so those counters read zero
  there)
- `RGSS::Profiler.stats` returns the current interval as a Hash for tests and
  ad-hoc measurement; `report`/`reset` force or clear an interval
- Chrome trace export (`--profile_trace=FILE`, or `RGSS::Profiler.trace_start`/
  `trace_stop`): frames and sections are streamed as Chrome Trace Event `X`
  (complete) events on one thread track — so they nest into a flame chart in
  `chrome://tracing` / Perfetto — and each per-interval memory sample as `C`
  (counter) events. The writer streams events to the file with a comma-prefix
  scheme and flushes each interval; the format's tolerance of a missing closing
  bracket means a trace truncated by a crash or `Ctrl-C` still loads. The trace
  is closed from `mrb_mruby_rgss_gem_final` on the native path

## Third party libraries
- Third party libraries is placed to `3rd/` directory

## Development flow
- For basic testing run `clear ; cmake --build build && cmake --build build -t test` to run basic tests
- Issues and pull requests are labelled by engine, platform, component and type
  — see `docs/labels.md` for the taxonomy and how the labels get applied
