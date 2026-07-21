# 1. Terminal gaming with the sixel graphics protocol

Date: 2026-07-20

## Status

Accepted

## Context

The runtime only had a single display backend: an SDL window created with
`lv_sdl_window_create`. That requires a desktop windowing system, which
conflicts with a core project goal — running RPG Maker games "on any
environment such like embedded boards". It also makes the runtime awkward to
use over SSH or on headless CI hosts.

LVGL (already the rendering layer) is display-agnostic: a display is just a
framebuffer plus a flush callback. Many terminals (xterm in vt340 mode, mlterm,
foot, WezTerm, Windows Terminal, ...) can display bitmap images inline via the
DEC **sixel** protocol. That makes a terminal a viable render target with no
new windowing dependency.

Two integration concerns had to be solved:

- **Timing.** Without SDL there is no tick source, and LVGL needs one for
  `lv_tick_get`/`lv_delay_ms` (used by the frame limiter and the timeout).
- **Input.** `RGSS::Input` was a stub with no C++ wiring, and terminals do not
  report key-release events.

## Decision

Add a second, windowless display backend (`mruby-rgss/src/sixel.cxx`), selected
at runtime with the `--sixel` flag (`--sixel_scale` controls integer upscaling):

- Create the display with `lv_display_create` in `LV_DISPLAY_RENDER_MODE_FULL`
  backed by an RGB565 full-screen buffer, so each flush holds the whole frame.
- The flush callback encodes the frame to sixel and writes it to the terminal.
  Colours are quantised to a fixed 6×6×6 (216-entry) cube so encoding stays
  `O(pixels)` with no palette search; bands are run-length encoded.
- Provide a monotonic-clock tick source and a `nanosleep`-based delay via
  `lv_tick_set_cb` / `lv_delay_set_cb`.
- Put the terminal into raw mode (restored on exit and on fatal signals) and
  read keys directly. Because there are no key-up events, a key is held for a
  short window (`HOLD_MS`) after its last byte; the terminal's own auto-repeat
  sustains held movement keys. Input is forwarded to `RGSS::Input` from
  `Graphics.update` through the exported `rgss_terminal_poll` hook.

## Consequences

- The runtime can now be played on hosts without a GUI, advancing the
  "run anywhere" goal.
- SDL remains the default; the sixel path is fully opt-in, so existing behaviour
  is unchanged.
- Trade-offs / follow-up work:
  - The fixed 216-colour palette limits fidelity; an adaptive palette (or
    libsixel) could improve quality later.
  - Terminal input has no key-release, so `HOLD_MS` is a heuristic; held-key
    feel depends on the terminal's auto-repeat settings.
  - The backend lives inside the `mruby-rgss` gem (so it is part of
    `libmruby.a` and links into both the game executable and mruby's own
    `mrbtest` binary). `main.cxx` calls the exported `sixel_display_create`,
    mirroring the existing `rgss_set_display` seam.
