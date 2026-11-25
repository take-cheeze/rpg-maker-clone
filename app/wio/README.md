# Wio Terminal firmware

The Wio Terminal (Seeed, ATSAMD51) runs the **closed-world** RPG2k/2003 engine:
the Ruby is compiled by bc2cpp into C++ and linked into a VM-free libmruby, with
mruby-rgss's LVGL display and input HAL under it. There is no interpreted Wio
build, and no demo firmware.

## Building

The `wio` environment links a libmruby and uni-algo built outside
`platformio.ini`:

```sh
# the lists proven for the wio world (bc2cpp's closed-list proof)
export BC2CPP_STATIC_DISPATCH_LISTS="$(BC2CPP_LISTS_WORLD=wio scripts/bc2cpp/static_dispatch_lists.bash)"
RPGMAKER_BC2CPP=1 MRUBY_TARGET=wio \
  RGSS_WIO_ARDUINO_INCLUDES=<colon-separated PlatformIO framework -I dirs> \
  rake                                          # libmruby.a (closed world)
# uni-algo: a standalone arm-none-eabi cross-build of 3rd/uni-algo
WIO_MRUBY_BUILD_DIR=<that build>/wio \
WIO_UNIALGO_LIB_DIR=<uni-algo lib dir> \
  pio run -e wio
```

`scripts/wio/build.bash` runs all of it from a bare checkout (in `nix develop .#bc2cpp`), as CI's
`wio` job does.

## The QSPI flash image

The engine is too big for the board's 496 KB of internal flash, so the cold part of it runs in place from the
board's 4 MB QSPI flash. A `wio` link writes two images, and the board needs both, from the same build:

| Image | Goes to | Written by |
|---|---|---|
| `.pio/build/wio/firmware.bin` | internal flash | `pio run -e wio -t upload` (the UF2 bootloader) |
| `.pio/build/wio/firmware_qspi.bin` | QSPI flash, first 1.5 MB | the `wio_qspi_flash` loader |

The bootloader cannot write the QSPI flash. To program it:

1. Copy `firmware_qspi.bin` to the microSD card as `/qspi.bin` (a card reader, or `scripts/wio/sd_upload.py`).
2. `pio run -e wio_qspi_flash -t upload`, then wait for `DONE verified` on the serial monitor.
3. `pio run -e wio -t upload`.

If the QSPI image is missing, damaged or from another build, the firmware shows why on the LCD and the serial port
and blinks the user LED instead of starting. `WIO_QSPI_XIP=0 pio run -e wio` links everything into internal flash
(it does not fit). `app/wio/qspi_xip_placement.txt` chooses what goes to QSPI, and `app/wio/qspi_xip_hot.txt` keeps
the code a map or battle frame spends its QSPI cache misses in internal. To redo the latter, trace a few scenes with
`scripts/wio/renode_game.bash --trace FILE` and run `scripts/wio/qspi_xip_hot.rb`.

`MRUBY_TARGET=wio` without `RPGMAKER_BC2CPP=1` fails in `build_config.rb`.
`env:wio` is `app/wio/src/wio_rgss_boot_main.cxx`, which boots the compiled
engine.

## Renode: `wio_sim`

`pio run -e wio_sim -t upload` builds `wio` and boots it under the project's Renode
emulator instead of flashing a board. Renode is not a repo dependency: build it with
`scripts/wio/renode_build.bash` and set `RENODE_BIN`. See `app/wio/renode/README.md`.

## `wio_sd_upload`: no SD card reader

`pio run -e wio_sd_upload -t upload` flashes a throwaway loader that writes
files to the microSD card over the USB-CDC serial connection, for a dev machine
with no way to pull the card out and mount it. Drive it with
`scripts/wio/sd_upload.py`:

```sh
pio run -e wio_sd_upload -t upload
scripts/wio/sd_upload.py <local file>:<path on the card>
pio run -e wio -t upload        # reflash the game afterwards
```

See `app/wio/src/sd_upload_main.cxx` for the serial protocol.
