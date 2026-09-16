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
`"maix-ruby-alive"`, and reports it over Serial. The boot firmware now also
paints solid red through a real LVGL display (see "Display HAL" below) and
polls input into RGSS::Input every frame (see "Input"). No game scene yet.
The link itself is the measurement:

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

## Status: P2 — a real game boots to title

`pio run -e maix_game` boots `data/maix-hello` -- a synthetic 3-file game
authored by `scripts/gen-maix-hello-game.rb` (56-byte database, 23-byte
map tree, generated title picture; nothing vendored) -- to its RPG2k title
screen: display, input, interpreter, flash-resident game behind
`GAME_DIR=/game` (baked in at build time by `app/maix/embed_game.py`,
served by `maix_embed.cxx`), one `main_loop` per Arduino `loop()`.
`maix-smoke` asserts the `RPG2k::Scene::Title` marker and replays the
captured frame (teal background, white border and menu text, window
shades) through the same LCD check.

Two load-bearing findings from bringing this up, both firsts for the
embedded ports: the Kendryte link drops every `.eh_frame` section, so
mruby's C++-exception control flow cannot unwind -- `MRUBY_FORCE_NO_CXX_EXCEPTION`
(setjmp/longjmp, mruby's portable fallback) is on for this target, and the
first rescued `NoMethodError` on-device is what proved it; and the stub
`RGSS::Profiler` must still define the `frame`/`section` yield-through
methods, because the real game loop (unlike any bring-up) calls them every
frame.

The panel itself needed two more real-hardware fixes on top: the driver's
default `MADCTL` (`DIR_YX_RLDU`) renders mirrored left-to-right --
`DIR_YX_LRDU` fixes it, same orientation and dimensions, only the column
order flips back -- and this panel variant powers up BGR *and* inverted
relative to what the driver assumes (a white paint reads back black, blue
reads back cyan); `INVERSION_DISPALY_OFF` alongside the `DIR_YX_LRDU`
change is the combination the hardware color probe found true. The flush
itself is banded (four quarter-frame `tft_write_half` transfers instead of
one `drawImage` call) and byte-swapped per pixel -- a single giant DMA
truncates and many small ones alternate-drop on real silicon, confirmed by
probing, so the band count is not arbitrary.

## Status: SD-card game boot -- blocked

`pio run -e maix_game_sd` is the same firmware as `maix_game`, but reads
its data from the microSD card (`GAME_DIR=/sd/maixgame`, pushed with
`scripts/maix_sd_upload.py`) instead of the flash-embedded copy, over the
SD layer described below. It compiles and mounts the card, but does not
boot: on real hardware it hangs solid partway through the interpreter's
first data-cluster read. Isolated with a raw `fopen`/`fread` bypassing
mruby entirely -- `fopen` succeeds (the directory-area reads that resolve
it all work, including a fresh re-upload, ruling out stale data), but the
first `fread()` on the file's own data cluster never returns. Reproduces
identically regardless of which K210 SPI peripheral drives the card
(SPI0 or SPI1, see "SD layer" below) and independent of clock speed (4 MHz
or 400 kHz) -- so it is neither a bus-sharing nor a signal-rate issue, at
least not one clock-speed alone fixes. Not a Renode target either way (no
SD controller modeled), so CI only compile-proves it. See
`app/wio/src/maix_game_main.cxx`'s `KNOWN ISSUE` comment for the full
trail; next step is likely a scope/logic analyzer on the SPI lines, or a
different SD card to rule out a media-specific fault.

## Display HAL (PlatformIO side)

`app/wio/src/maix_display.cxx` (selected by `platformio.ini`'s
`maix_rgss_boot` filter; declared in `include/maix.hxx`) stands up the LVGL
display over the panel through the same Sipeed_ST7789 driver the P0
firmware uses: a full-frame RGB565 buffer from the newlib heap, flushed
per dirty rectangle with the driver's own `drawImage`. Deliberately
PIO-side rather than in `libmruby.a` like Wio's `wio.cxx`: it needs
Arduino/SPI/LCD headers the rake cross-build never sees, and the firmware
links LVGL itself, so nothing pays the Arduino-include escape-hatch price.
The mruby side needs no counterpart -- `lib.cxx` already reaches an
injected display through `rgss_set_display`.

Two gotchas, both confirmed against the capture rig: the display is
320x240 (the largest window the driver was ever observed to address -- the
panel's nominal 320x480 vs rotation is still a real-hardware follow-up:
nothing has attempted the other 240 rows on real hardware yet, and LVGL
must render in driver space either way), and a screen needs an explicit
opaque background style -- with no theme the default is transparent and
renders as white. The boot firmware paints solid red through LVGL itself;
the wire shows it byte-swapped (`00F8`, the driver's `SWAP_16`), which is
what the decoder asserts. On-panel color truth (not just the wire bytes)
is confirmed against real hardware -- see the color-fix paragraph under
"Status: P2" above.

## Input (PlatformIO side)

`app/wio/src/maix_input.cxx`: a minimal FT6X36 capacitive-touch reader
(I2C1 via `Wire1`, five registers, no vendor library -- Maixduino ships
none for this chip) scanned into a bitmask, plus `rgss_maix_poll`, which
diffs it against the previous frame into `RGSS::Input.press`/`release`
(the SDL bridge's shape). A tap is Confirm; directions (touch regions)
belong to the menu work that needs them. `lib.cxx` calls the poll from
`input_poll` under `MAIX_BUILD`, so the real game loop drains it for free;
firmwares without one call it directly. With no panel attached (Renode
included) every read is zero -- exactly the idle state, never a hang
(the I2C status/FIFO Tags in `boot.resc` are what guarantee that).

## SD layer (opt-in)

`app/wio/src/maix_sd_syscalls.cxx` routes newlib `_open`/`_read`/`_write`/
`_lseek`/`_fstat`/`_unlink` (plus stdout/stderr to Serial) to Maixduino's
SD library over SPI1's TF slot (SCK 11 / MISO 6 / MOSI 10, chip-select
26), with the same `/sd/<game>` `GAME_DIR` convention Wio uses. SPI1, not
SPI0, confirmed against the official schematic (every TF-slot net is
literally named `SPI1_*` on the real PCB) -- an earlier revision used
SPI0 with the right pins but the wrong peripheral, which meant fighting
the LCD (also SPI0, see "Display HAL" above) over the one sysctl mux bit
that picks whether SPI0's data lines answer to the SPI controller or the
DVP camera interface. SPI1 has no such sharing, so the LCD and the SD
card are now genuinely independent buses. Compiled only with
`MAIX_WITH_SD` (CI builds it once that way as a compile proof, via
`PLATFORMIO_BUILD_FLAGS`); call `maix_sd_init()` from `setup()` before
opening anything. Runtime proof needs a physical card -- Renode models no
SD controller -- and on real hardware it currently hangs past the first
data-cluster read; see "Status: SD-card game boot" above.

## Pushing files without a card reader

`pio run -e maix_sd_upload` builds a throwaway loader that writes files to
the microSD card over the same USB serial used for flashing -- for a dev
machine that cannot pull the card out and mount it directly. Same
PING/PUT protocol as the Wio loader, driven by
`scripts/maix_sd_upload.py`:

```sh
pio run -e maix_sd_upload -t upload --upload-port /dev/ttyUSB1
scripts/maix_sd_upload.py \
  /tmp/maixhello/RPG_RT.ldb:/sd/maixgame/RPG_RT.ldb \
  /tmp/maixhello/Title/maix.png:/sd/maixgame/Title/maix.png
pio run -e maix_game -t upload --upload-port /dev/ttyUSB1  # reflash real fw
```

Remote paths must stay 8.3 -- the bundled sdfat has no long-filename
support, so a remote like `/sd/maixhello/...` (9 chars) can never be
created; that is why the example uses `/sd/maixgame/`.

Port notes, confirmed against real hardware: the Amigo exposes two UARTs
and only the second (`/dev/ttyUSB1` here) answers kflash; the console lives
on that same port.

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
transfer into `$MAIX_SPI_LOG` as `D <dc> <hex32> <frame_bytes>` lines,
sampling DC live from GPIO 7 (the driver's fixed DC line). `frame_bytes`
comes from SPI0's own `ctrlr0` frame-size register, not the DMAC's
memory-access width: `tft_write_half` (the banded flush's 16-bit-frame
transfer) still gets DMA'd in 32-bit-padded memory units regardless, so
the DMAC's own width tag cannot tell a real second pixel from that
padding -- confirmed the hard way when it silently halved every real
pixel in the capture. The non-incrementing-source (`sinc`) fill transfers
are replayed from their single word -- reading them as incrementing walks
into zeros and heap garbage, confirmed the confusing way.
`scripts/maix_lcd_decode.py` (stdlib only) replays the ST7789 stream
(CASET/RASET/RAMWR, RGB565, `frame_bytes // 2` pixels per capture line)
into a PPM and checks it: currently a blue 320x240 screen with two white
text lines at the firmware's own cursor rows, asserted as blue ≥ 0.45,
≥ 3 colors, 320x240 extent.

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

- **SD-card game boot**: still hangs on real hardware -- see "Status:
  SD-card game boot" above. Blocks everything past a flash-embedded test
  game (no real RTP-using game has been tried, no saves).
- **Full 320x480 panel / rotation**: only the 320x240 window has ever been
  driven on real hardware; whether the other 240 rows are addressable, and
  whether that is the whole physical panel or needs a rotation, is
  unresolved.
- **Menu-navigable input**: touch only maps a tap to Confirm; there is no
  directional input, so nothing past the title screen is actually
  playable yet.
- **LCD controller check**: Amigo shipped as TFT and IPS panel revisions
  (two different schematics, `Maix_Amigo_2960`/`Maix_Amigo_2970`); the
  color/orientation fixes above were verified against one physical unit,
  not both revisions.
