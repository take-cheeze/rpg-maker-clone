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

## Classes in flash (ROM class graph)

`WIO_ROM_GRAPH=GRAPH.c scripts/wio/build.bash` links the class graph the boot leaves as const data, so the classes,
modules, singleton classes and their constant tables are in internal flash instead of the heap. The graph is made
under Renode from the same libmruby (`RENODE_BIN`, see `renode/README.md`):

```sh
scripts/wio/build.bash                                   # libmruby, a firmware with no graph
scripts/wio/rom_graph.bash dump build-wio GAME_DIR graph.c
WIO_ROM_GRAPH=graph.c scripts/wio/build.bash             # the firmware on the graph
scripts/wio/rom_graph.bash check build-wio GAME_DIR graph.c   # a boot on it leaves the same graph
```

A graph from another libmruby fails to compile or to boot; rebuild it after a change to the engine. Without
`WIO_ROM_GRAPH` every class is on the heap. A class's structure is fixed once it is in the graph (mruby's
`doc/guides/rom-class-graph.md`); its constants and class variables still change, in a heap copy.

CI's `wio` job runs these four steps on every build, so the `wio` and `wio_renode_game` firmware it uploads are on a
graph of their own libmruby; it fails if the check does or the image overflows internal flash. The dump stops before
a game loads, so the game it boots (`scripts/gen/wio-sd-game.rb`) does not change the graph.

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

The developer tools (F9 debug menu, map viewer/editor, chipset editor) are not in the Wio firmware: F9 does
nothing. `WIO_DEBUG_SCENES=1` at build time keeps them.

The engine is compiled from a rewritten copy of its mrblib (`scripts/wio/world_strip.rb`): by default, helpers with
one caller are folded into it. `WIO_WORLD_STRIP=0` compiles the source as it is, and a list such as
`WIO_WORLD_STRIP=inline,debug` picks the passes. `debug` also removes the `[RPG2k]` error lines from the stderr log.

## Game data on the microSD card

The firmware takes the game's files from the microSD card when it has a `/rpg2k` folder holding the game folder's
contents (`/rpg2k/RPG_RT.ldb`, `/rpg2k/Title/...`); otherwise from the game image in the QSPI flash. The card must be
FAT12/16/32: exFAT (how SDXC cards of 64 GB and up come) is not read. Japanese file names work. The boot screen and
the `[Wio]` log lines say where the files come from, or why the card was not used. `WIO_SD=0` at build time leaves
the card driver out.

A card game's palette images can come already decoded: `scripts/wio/sd_bitmaps.rb GAME_DIR` writes
`GAME_DIR/wio_bitmaps.bin`, which goes on the card as `/rpg2k/wio_bitmaps.bin` (rebuild it whenever the images
change). The firmware then copies each image into the QSPI flash after the code and game images the first time it is
drawn (about 45 ms per 4 KB erased, plus the card read) and draws it from there instead of decoding its PNG into RAM;
later boots keep what was copied, and the oldest copies make room for new ones. Without the file, or for an image that
cannot be copied, the PNG is decoded as before, and a `[Wio] image cache:` line says why. The same region holds the
card's `RPG_RT.ldb` and maps once read (`[Wio] file cache:` lines), which are then read in place, so a large map needs
no room in RAM; the first boot copies the database (1.3 MB for Nepheshel) before the title. The pack's checksum covers
the game's LCF files, so rebuild it whenever the game changes. `wio` itself does not play the game yet; `wio_renode_game` does, under Renode.

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
