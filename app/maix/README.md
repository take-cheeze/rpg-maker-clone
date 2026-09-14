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

## Status: P1 — libmruby links and boots

`pio run -e maix_rgss_boot` (with `MAIX_MRUBY_BUILD_DIR` /
`MAIX_UNIALGO_LIB_DIR` pointing at the two cross-build outputs below) links
the `maix` cross `libmruby.a` plus LVGL into a firmware whose `setup()`
opens the interpreter (the full RPG2k+LCF+RGSS gem init), evaluates
`"maix-ruby-alive"`, and reports it over Serial. No display HAL or game
scene yet. The link itself is the measurement:

```
RAM:   110,924 bytes from 6,291,456 bytes (1.8%)
Flash: 3,122,555 bytes from 8,388,608 bytes (37.2%)
```

Three link findings, each confirmed by a real link failure first: the rake
build of mruby-rgss must see this port's own `lv_conf.h`
(`mruby-rgss/mrbgem.rake`, same mismatch Wio hit and documents);
`LV_USE_LOG` stays on here (untrimmed `lib.cxx` reaches `lv_log_add`
through LVGL's own inlines); and the smoke's runtime string eval needs
`mruby-compiler` in the gem set (production loading uses precompiled
bytecode, so it can go again later).

```sh
scripts/maix_mruby_build.bash      # ./build-maix-mruby (libmruby.a)
scripts/maix_unialgo_build.bash    # ./build-maix-unialgo (libuni-algo.a)
MAIX_MRUBY_BUILD_DIR=$PWD/build-maix-mruby/maix \
MAIX_UNIALGO_LIB_DIR=$PWD/build-maix-unialgo \
  pio run -e maix_rgss_boot
```

## The mruby cross-build (PSP-style)

`scripts/maix_mruby_build.bash` builds `build_config.rb`'s `maix`
`MRuby::CrossBuild`: a native host mruby first (for `mrbc`), then the
riscv64 cross `libmruby.a` (RV64IMACFD, `medany/lp64f/rv64imafc` to match the
firmware half) the firmware links in a later slice -- the PSP EBOOT pipeline's
exact analog. Single-format RPG2k-only, like the PSP/Wio builds (no
XP/VX/Wolf/MV, no onigmo). Two Kendryte-toolchain findings, both verified by
building, are documented in the stanza: bare newlib's hard `#error` on
`<dirent.h>` (shared `hal-wio-io`, plus `MAIX_BUILD` gates for the dirent
paths) and its libstdc++ missing C99 stdio/TR1 (`_GLIBCXX_USE_C99_STDIO=1`,
`::lround` at the kept call sites).

```sh
scripts/maix_mruby_build.bash            # ./build-maix-mruby/maix/lib/libmruby.a
scripts/maix_mruby_build.bash /tmp/maix  # ...or wherever
```

Needs `ruby`, `rake`, `bison`, `gperf` and the Kendryte toolchain (present
after any `pio run -e maix_amigo`, which the stanza prefers); the Unicode
tables are fetched with the same pins/hashes the `psp` CI job uses.

## Emulation (Renode)

`scripts/maix_renode_boot.bash` boots a firmware ELF under **stock**
Renode -- no from-source build the way `wio-renode` needs: Renode ships the
K210 SoC description (dual RV64, UARTHS, CLINT, PLIC) since 1.9, with only
small Python stubs in `app/maix/renode/` on top. CI's `maix-smoke` job
boots the `maix_rgss_boot` ELF (pinned to Renode 1.17.0) and asserts
`REACHED setup()`, `mrb_open ok`, `eval -> maix-ruby-alive`,
`REACHED loop()`.

```sh
RENODE_BIN=/path/to/renode scripts/maix_renode_boot.bash \
  .pio/build/maix_rgss_boot/firmware.elf
```

## LCD capture (Renode + host decode)

The panel cannot render inside the emulator, but every byte headed for it
can be caught: the LCD driver moves each command/pixel block with the AXI
DMAC into SPI0's data register, so `app/maix/renode/` carries a small AXI
model (remembers SAR/DAR/BLOCK_TS/CTL per channel -- a plain Tag cannot
even do that) plus a copy hook on `dmac_channel_enable` that replays each
transfer into `$MAIX_SPI_LOG` as `D <dc> <hex32>` lines, sampling DC live
from GPIO 7 (the driver's fixed DC line). The non-incrementing-source
(`sinc`) fill transfers are replayed from their single word -- reading
them as incrementing walks into zeros and heap garbage, confirmed the
confusing way. `scripts/maix_lcd_decode.py` (stdlib only) replays the
ST7789 stream (CASET/RASET/RAMWR, RGB565) into a PPM and checks it:
currently a blue 320x240 screen with two white text lines at the firmware's
own cursor rows, asserted as blue ≥ 0.45, ≥ 3 colors, 320x240 extent.

```sh
RENODE_BIN=/path/to/renode \
MAIX_SPI_LOG=/tmp/maix-spi.log \
  scripts/maix_renode_boot.bash .pio/build/maix_amigo/firmware.elf 00:00:08
python3 scripts/maix_lcd_decode.py /tmp/maix-spi.log /tmp/maix-frame.ppm \
  --min-blue 0.45 --min-colors 3 --expect-size 320x240
```

Renode-scope notes, each confirmed by a real probe run and worth knowing
before touching this: peripheral request handlers cannot touch the bus
(only the CPU hooks can, via the `machine` variable -- `self` is the CPU
there and something else again in `include`d files); bus *writes* from
hooks never reach Python peripherals (reads do), so the hook appends to
the capture file itself instead of replaying onto the bus; hook strings
cannot see `include`d files' globals (register with the function object,
not by name); `.repl` takes no `#` comments; and `logLevel 3` quiets the
UART analyzer into total silence (info-level logging is load-bearing).

CI's `maix-smoke` job (pinned to Renode 1.17.0) asserts all four markers.
Note the `boot.resc` gotcha its own comment records: info-level logging is
load-bearing -- `logLevel 3` quiets the UART analyzer into silence.

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
