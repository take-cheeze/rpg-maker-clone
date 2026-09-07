# Wio Terminal firmware

A PlatformIO/Arduino firmware target that runs the RPG2k runtime on the
[Wio Terminal](https://www.seeedstudio.com/Wio-Terminal-p-4509.html) (Seeed,
ATSAMD51: Cortex-M4F @120 MHz, 512 KB flash, 192 KB SRAM, 320×240 ILI9341 LCD,
3 buttons + 5-way switch, microSD).

This is additive to and independent of the desktop CMake build — building the
firmware does not touch the desktop/wasm builds, and vice versa. The design and
memory-budget analysis are in
[`docs/adr/0007-wio-terminal-port.md`](../../docs/adr/0007-wio-terminal-port.md).

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

## The other environment: `wio_walk`, a map you can walk today

`pio run -e wio_walk` builds something different in kind: the **minimal,
non-mruby map-walking engine** written for the iPod nano 7th generation
(`docs/adr/0061`), on this board's LCD, SD card and 5-way switch. The engine
itself is shared source — `app/shared/rpg2k_walk/rpg2k_walk_core.c`, the same
C the nano app runs (`docs/adr/0091`) — and `app/wio/src/walk_main.cxx` is
only the board wiring. It links **neither LVGL nor mruby**.

It can run now, with none of the P2/P3 work above, because the interpreter's
work already happened on the host: `scripts/export_nano7_map.rb` does the LCF
parsing, autotile assembly, chipset compositing and passability resolution
under plain CRuby and writes two flat files.

```sh
ruby scripts/export_nano7_map.rb --target wio \
  data/Nepheshel206beta/Nepheshel206Nbeta 1 /tmp/rpg2k_walk_out
# copy map.bin and tiles.bin into /RPG2kWalk/ on the microSD card
pio run -e wio_walk -t upload
```

`--target wio` sizes the export for this board's buffers (128x128 tiles, 192
atlas entries — about 90 KB of its 192 KB SRAM) and refuses a map that would
not fit rather than writing one the firmware cannot load. That is the same
map bound the iPod nano 7G takes: the format shrank to 2.5 bytes a cell
(`docs/adr/0093`), so this board's cap doubled twice while its SRAM use went
down. Hold a direction on
the 5-way switch to walk; collision is the map's real passability data.

**Scope, and status.** It walks one static map, with the water animating on
RPG2000's own clock (`docs/adr/0094`): no events, no battle, no
menus, no interpreter — see the ADRs before expecting a game. CI compiles it
(the `wio` job builds both environments) and the shared core has its own host
test (the `walk_core` ctest). It has now run on real hardware — a real
Nepheshel map, exported and copied to the card as above, walks correctly on
the board's LCD with the 5-way switch. The `wio` bring-up firmware above is
still untried on a board.

### No SD card reader? `wio_sd_upload`

`pio run -e wio_sd_upload -t upload` flashes a throwaway loader that writes
files to the microSD card over the same USB-CDC serial connection used to
flash the board, for a dev machine with a Wio Terminal but no way to pull the
card out and mount it directly. Drive it with `scripts/wio_sd_upload.py`:

```sh
pio run -e wio_sd_upload -t upload
scripts/wio_sd_upload.py \
  /tmp/rpg2k_walk_out/map.bin:/RPG2kWalk/map.bin \
  /tmp/rpg2k_walk_out/tiles.bin:/RPG2kWalk/tiles.bin
pio run -e wio_walk -t upload   # reflash the firmware you actually want running
```

See `app/wio/src/sd_upload_main.cxx` for the (tiny) serial protocol.

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
