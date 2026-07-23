# 3. Terminal gaming with the iTerm2 inline-image protocol

Date: 2026-07-22

## Status

Accepted

Extends [1. Terminal gaming with the sixel graphics protocol](0001-terminal-gaming-sixel.md).

## Context

ADR 0001 added a windowless display backend that renders each frame to the
terminal with the DEC **sixel** protocol. Sixel is widely supported (xterm in
vt340 mode, mlterm, foot, WezTerm, Windows Terminal, ...) but there is one
common environment where it does *not* work: **VS Code's integrated terminal**.
That terminal is built on xterm.js, whose image addon implements the **sixel**
and **iTerm2 inline-image** protocols but *not* the kitty graphics protocol.
Since developers frequently run the game straight from the editor, a backend
that renders there is valuable.

The iTerm2 inline-image protocol also fixes two fidelity/bandwidth limitations
called out in ADR 0001:

- Sixel here quantises to a fixed 216-colour cube. iTerm2 payloads are ordinary
  image files, so we get full 24-bit colour with no banding.
- The sixel encoder re-emits the ~3.2 KB palette every frame and is otherwise
  ~1 byte/pixel. An image file can be PNG-compressed, and the large flat
  tile/sprite regions typical of RPG Maker games compress heavily.

The protocol is understood by iTerm2, WezTerm and xterm.js (hence VS Code), so
one backend covers all three.

## Decision

Add a third display backend selected with `--iterm` (`--iterm_scale` controls
integer upscaling), alongside the existing `--sixel`.

Because the sixel and iTerm2 backends differ *only* in how a finished frame is
turned into bytes, the shared machinery from `sixel.cxx` was extracted into a
new **`mruby-rgss/src/terminal.cxx`** (declared in `include/terminal.hxx`):

- LVGL display creation in `LV_DISPLAY_RENDER_MODE_FULL` backed by an RGB565
  full-screen buffer.
- The monotonic-clock tick source and `nanosleep`-based delay
  (`lv_tick_set_cb` / `lv_delay_set_cb`).
- Raw-mode terminal setup, alternate-screen switching, cursor hiding, and
  restoration on exit and fatal signals.
- Keyboard polling (arrows/WASD, confirm, cancel, quit) forwarded to
  `RGSS::Input`, exported as `rgss_terminal_poll`.
- The one-line control legend drawn on the top row above the frame, exposed as
  `terminal_append_legend` so both encoders emit the identical hint (added for
  sixel on `master`; the shared helper lets the iTerm2 path draw it too).

`terminal_display_create(w, h, scale, encode)` takes a per-protocol encoder
callback; `sixel.cxx` and `iterm.cxx` now contain *only* their encoder plus a
thin `*_display_create` wrapper. This keeps the two backends in lockstep on
input, timing and teardown.

The iTerm2 encoder (`mruby-rgss/src/iterm.cxx`):

- Expands the RGB565 frame to RGB888, upscaling by an integer nearest-neighbour
  factor.
- Encodes it to PNG with `stb_image_write` (already vendored in `3rd/stb`),
  which bundles its own deflate implementation so no zlib dependency is added.
  `STBI_WRITE_NO_STDIO` keeps only the in-memory `*_to_func` API. The
  compression level is lowered from stb's default of 8 to 6 to favour encode
  latency on the game loop.
- base64-encodes the PNG and wraps it in the OSC 1337 sequence
  `ESC ] 1337 ; File=inline=1;size=N;width=Wpx;height=Hpx;preserveAspectRatio=0 : <base64> BEL`.
  A leading `ESC[H` (cursor home) makes each frame overdraw the previous one in
  place, mirroring the sixel path.

## Bandwidth

Unlike sixel's ~1 byte/pixel, the iTerm2 path is PNG-compressed, so frame size
depends heavily on content. A frame is `PNG(frame) × 4/3` bytes on the wire
(base64 overhead):

- Flat/gradient regions compress dramatically — a synthetic 120×72 test frame
  of gradients plus flat blocks encoded to **447 bytes** of PNG (596 bytes
  base64), versus 25,920 bytes of raw RGB.
- Busy, high-entropy frames compress far less; the ceiling approaches the raw
  RGB size (`w × h × 3 × scale²`) plus base64 overhead before PNG's own header.

So for the flat tile/sprite regions typical of these games the iTerm2 path is
usually *lighter* on the wire than sixel, at the cost of **CPU spent on PNG
deflate every frame** — the opposite trade-off from the sixel encoder, which is
cheap to compute but bulky. As with sixel, `--iterm_scale` multiplies the pixel
work (and the worst-case byte count) by `scale²`, and the backend targets a
local PTY or SSH pipe rather than a real UART.

## Consequences

- The runtime now renders in VS Code's integrated terminal (and iTerm2 /
  WezTerm), where sixel and kitty do not both work — broadening the "run
  anywhere" goal.
- Full 24-bit colour with no palette banding on this path.
- `--sixel` and `--iterm` are mutually exclusive; `main.cxx` rejects passing
  both. SDL remains the default and is unchanged.
- Trade-offs / follow-up work:
  - PNG encoding costs CPU per frame; on a slow host the frame rate may need to
    drop. Lowering the compression level or diffing against the previous frame
    (the iTerm2 protocol has no built-in delta, unlike kitty) could help.
  - Terminal input still has no key-release, so the `HOLD_MS` heuristic from
    ADR 0001 applies unchanged (it now lives in `terminal.cxx`).
  - The backend continues to live inside the `mruby-rgss` gem, linking into both
    the game executable and mruby's `mrbtest`; `main.cxx` calls the exported
    `iterm_display_create`, mirroring the `sixel_display_create` seam.
