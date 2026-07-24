# Wio Terminal firmware

A PlatformIO/Arduino firmware target that runs the RPG2k runtime on the
[Wio Terminal](https://www.seeedstudio.com/Wio-Terminal-p-4509.html) (Seeed,
ATSAMD51: Cortex-M4F @120 MHz, 512 KB flash, 192 KB SRAM, 320×240 ILI9341 LCD,
3 buttons + 5-way switch, microSD).

This is additive to and independent of the desktop CMake build — building the
firmware does not touch the desktop/wasm builds, and vice versa. The design and
memory-budget analysis are in
[`docs/adr/0005-wio-terminal-port.md`](../../docs/adr/0005-wio-terminal-port.md).

## Status: P1 — HAL bring-up

The `wio` PlatformIO environment builds a **hardware bring-up firmware**: it
stands up the LVGL display over the LCD and reads the buttons, without the mruby
interpreter. It is the first slice of the roadmap in the ADR and exists to prove
the HAL compiles and runs on the board (and to get real flash/RAM numbers from
CI's `size` output).

What runs today:

- `mruby-rgss/src/wio.cxx` — the HAL: an LVGL v9 display in **partial** render
  mode (small draw buffer, not a 150 KB full framebuffer) flushing to the
  ILI9341 via `Seeed_Arduino_LCD`; the LVGL tick/delay source from Arduino
  `millis()`/`delay()`; and a scan of the 3 buttons + 5-way switch into a
  bitmask.
- `app/wio/src/main.cxx` — an Arduino sketch that draws a status screen and
  echoes the pressed keys. Arduino owns the loop (`loop()` pumps LVGL once),
  mirroring how the Emscripten build hands its frame loop to the host.
- `app/wio/lv_conf.h` — a board-tuned LVGL config with a small heap.

## Building

```sh
pio run -e wio            # compile the bring-up firmware
pio run -e wio -t upload  # flash a connected Wio Terminal
```

## Not yet wired (later slices)

The pieces below are scaffolded/checked in but **not** part of the bring-up
firmware:

- **mruby interpreter + game.** `mruby-rgss/src/wio_input_bridge.cxx` already
  translates the button bitmask into `RGSS::Input` press/release events
  (`rgss_wio_poll`, called from `Graphics.update`), and `build_config.rb` has a
  `wio` mruby ARM cross-build (`MRUBY_TARGET=wio`). Wiring `libmruby.a` into the
  firmware link and starting the real `RPG2k` scene tree is the next slice.
- **SD-backed assets.** `app/wio/src/sd_syscalls.cxx` routes newlib
  `_open`/`_read`/… to the microSD card (gated behind `WIO_WITH_SD`); it feeds
  `File.open`/`fopen` once mruby is linked.
- **Fitting flash/RAM.** Per the ADR, the full gem set (onigmo, uni-algo, …)
  likely overruns the 512 KB internal flash, and whole-file asset loading
  overruns SRAM. Gem trimming (P2) and streaming asset loading (P3) follow the
  measurements from this bring-up.
