# Maix Amigo firmware

A PlatformIO/Arduino firmware target for the [Sipeed Maix Amigo](https://wiki.sipeed.com/soft/maixpy/en/develop_kit_board/maix_amigo.html)
(Kendryte K210: dual-core 64-bit RISC-V @ 400 MHz, 8 MB on-chip SRAM, 16 MB
flash, 3.5-inch 320x480 TFT with capacitive touch, microSD, speaker/mic).

This is additive to and independent of the desktop CMake build and the Wio
Terminal firmware — building it touches neither, and vice versa.

## Status: P0 — hello-world + LCD bring-up

`pio run -e maix_amigo` builds a **bring-up firmware**: Serial hello plus the
on-board TFT init through the Maixduino `Sipeed_ST7789` driver over SPI0, with
a blinking LED and a Serial heartbeat in `loop()`. No LVGL, no mruby, no SD
yet. It exists to prove the toolchain produces a binary for this board at all.

```sh
pio run -e maix_amigo            # compile the bring-up firmware
pio run -e maix_amigo -t upload  # flash a connected Maix Amigo (kflash)
```

## Why a custom board JSON (and a vendored variant)

The K210 PlatformIO platform (`sipeed/platform-kendryte210` v1.3.0) ships
board definitions only for BiT, Go, ONE DOCK, Maixduino and MF1 — there is no
Amigo board. The Maixduino Arduino core *does* carry the `sipeed_maix_amigo`
variant (pins, LCD, LEDs), so `boards/sipeed-maix-amigo.json` defines the
board around that variant (Maixduino `boards.txt` `amigo` section: `goE`
burn tool, 1.5 Mbps). If a future platform release adds a stock Amigo board,
this custom JSON should be retired in favour of it.

One more gap on top: the `framework-maixduino` package (~0.3.9) that platform
version installs predates the Amigo, so its `variants/` has no
`sipeed_maix_amigo` directory and the stock Arduino builder points CPPPATH at
a path that does not exist. The Amigo variant is header-only
(`pins_arduino.h`, vendored from Sipeed/Maixduino master into
`app/maix/variants/sipeed_maix_amigo/`), and `app/maix/add_amigo_variant.py`
(a `pre:` extra script on the environment) adds it to the include path.
Delete both once the framework package ships the Amigo itself.

## Footprint (P0)

```
RAM:   33,562 bytes from 6,291,456 bytes (0.5%)
Flash: 129,604 bytes from 8,388,608 bytes (1.5%)
```

The K210's 8 MB SRAM / 8 MB usable flash dwarf the Wio Terminal's 192 KB /
512 KB — the memory-budget pressure that dominates that port's roadmap does
not apply here. This environment also needs no git submodules (no LVGL).

## Source layout note

`platformio.ini` sets one project-wide `src_dir = app/wio/src`, so the Amigo
entry point lives at `app/wio/src/maix_amigo_main.cxx` and is selected by that
environment's `build_src_filter` (the `wio` environment explicitly excludes
it so its own `setup()`/`loop()` stay unique). Everything else about this
port lives here under `app/maix/`.

## Not yet wired (later slices)

- LCD controller check: Amigo shipped as TFT and IPS panel revisions; if the
  `Sipeed_ST7789` init mis-drives one revision, Serial stays the proof while
  the LCD is revisited.
- Touch input (FT6X36), SD-backed assets, LVGL display HAL, mruby cross-build.
