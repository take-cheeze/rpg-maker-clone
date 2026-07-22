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

## Bandwidth

Because the flush callback writes a full sixel frame to the terminal every
update, the output side is throughput-bound. The cost of one 320×240 frame
(`--sixel_scale 1`) with this encoder breaks down as:

- **Fixed header** (`ESC[H`, `ESC P q`, raster attributes, `ESC \`): ~30 bytes.
- **Palette**: the full 216-entry `6×6×6` cube is re-emitted every frame as
  `#i;2;r;g;b` definitions, ~3.2 KB.
- **Band data**: 40 bands of 6 rows. In each band a column emits one sixel data
  byte per *distinct* colour it contains (up to 6), so the ceiling is
  `6 × 320 × 40 = 76,800` bytes ≈ 1 byte per pixel. Run-length encoding
  (`!count`) only reduces this.
- **Colour-select overhead**: one `#n` per colour per band, plus `$`/`-`
  separators — up to a few tens of KB when bands are highly multi-coloured.

That gives roughly **15–40 KB** for a typical game frame (large flat
tile/sprite regions compress well) and up to **~120 KB** worst case.

At 60 Hz, and counting 10 bits/byte for 8N1 serial framing
(`baud = bytes/frame × 10 × 60`):

| Frame size | Baud (8N1) | Raw bits/s |
| ---------- | ---------- | ---------- |
| ~30 KB (typical) | ~18 Mbaud | ~14 Mbit/s |
| ~60 KB (heavy)   | ~36 Mbaud | ~29 Mbit/s |
| ~120 KB (worst)  | ~72 Mbaud | ~58 Mbit/s |

So sustaining 320×240 at 60 Hz needs on the order of **20 Mbaud typical, up to
~70 Mbaud worst case**. A conventional 115,200-baud serial console carries only
~11.5 KB/s — enough for ~0.3–0.7 fps, i.e. 150–600× too slow. The sixel backend
therefore targets a local PTY or an SSH pipe (effectively Mbit/s–Gbit/s), not a
real UART; on a genuinely slow link the frame rate must be dropped or the
resolution reduced. Note that `--sixel_scale` multiplies the byte count by
`scale²`.

Cheap levers if the link is the bottleneck: the palette is ~3.2 KB of *fixed*
overhead resent every frame (~190 KB/s at 60 Hz) and could be defined once per
session on terminals that persist colour registers across sixel sequences; and
lowering the frame rate scales the requirement linearly.

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
