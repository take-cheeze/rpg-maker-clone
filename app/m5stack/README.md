# M5Stack Core firmware

A PlatformIO/Arduino firmware target for the
[M5Stack Core](https://docs.m5stack.com/en/core/gray) (Basic/Gray/Go: ESP32
dual-core Xtensa LX6 @ 240 MHz, 320 KB SRAM, 4 MB flash, 320x240 ILI9341 SPI
TFT, three front buttons A/B/C) -- the unit the M5Stack "FACES" kit's
interchangeable bottom modules (keyboard/game/calculator/IoT) attach to.

This is additive to and independent of the desktop CMake build and the
Wio/Maix firmwares -- building it touches neither, and vice versa. Unlike
those two boards, PlatformIO's `espressif32` platform ships this board
natively (`m5stack-core-esp32`), so there is no custom `boards/*.json` here.

**This directory is its own standalone PlatformIO project** (`platformio.ini`
right here, not another environment in the repo root's) -- see that file's
own header comment and `docs/adr/0157-m5stack-core-qemu-emulator.md` for
why: this port needs `framework = arduino, espidf` ("Arduino as an ESP-IDF
component"), and PlatformIO's ESP-IDF/CMake build mode takes over the
*project root's* own `CMakeLists.txt` and cannot honor `build_src_filter` --
both fatal to sharing the repo root's `platformio.ini`/`CMakeLists.txt`/
`src_dir` the way the Wio Terminal and Maix Amigo ports do. Run every command
below from this directory (`cd app/m5stack`), not the repo root.

## Status: P1 -- HAL bring-up (LVGL display + input, no mruby yet)

`pio run -e m5stack` builds a **bring-up firmware**: the same shape as the
Wio Terminal's own `env:wio` P1 slice. `mruby-rgss/src/m5stack.cxx` (pulled
in via the `m5stack_hal.cxx` shim so it compiles without linking mruby,
mirroring `wio_hal.cxx`) stands up an LVGL display over the Core's ILI9341
through [TFT_eSPI](https://github.com/Bodmer/TFT_eSPI) -- configured
entirely by `build_flags` in `platformio.ini` (pins, driver, SPI frequency),
not a checked-in `User_Setup.h` -- and scans the three A/B/C buttons into a
bitmask. `src/main.cxx` draws a small status screen and echoes pressed keys
over Serial.

The Core has no built-in D-pad the way the Wio Terminal's 5-way switch is
one, so `include/m5stack.hxx`'s `M5Key` enum only ever sets the A/B/C bits;
Up/Down/Left/Right stay reserved and unbound (see that header's own comment).
Mapping three buttons onto a usable RPG movement scheme is a real product
design question for a later slice, not something this HAL-only bring-up
firmware answers.

```sh
cd app/m5stack
pio run -e m5stack            # compile the bring-up firmware
pio run -e m5stack -t upload  # flash a connected M5Stack Core
```

No mruby interpreter, SD-backed asset loading, or RGSS scene tree yet --
those are later slices, the same progression the Wio/Maix ports followed
(HAL bring-up first, then link `libmruby.a`, then real assets).

## Emulation (QEMU, not Renode)

See `docs/adr/0157-m5stack-core-qemu-emulator.md` for the full
investigation. In short: **Renode ships no usable ESP32/Xtensa foundation at
all** (checked directly against `renode/renode` and
`renode/renode-infrastructure` -- only one ESP32 peripheral,
`UART.ESP32_UART`, and a bare `xtensa-sample-controller.repl` test stub).
Two other suggested ESP32 emulators don't fit either, both checked directly
rather than by name: `espressif/esp-emulator` is real but RISC-V-only (no
classic Xtensa ESP32 support); `quantumnic/esp32emu` is a host-native API
mock, not a CPU emulator, and its `TFT_eSPI` mock doesn't implement the
bulk-push calls this port's own flush callback uses. **Espressif's own QEMU
fork** is the real fit: the same binary `idf.py qemu` uses, with a real,
actively-maintained ESP32 machine model (`hw/xtensa/esp32.c`) -- genuine
GPIO, SPI, UART, RTC, timer and eFuse peripherals, not stubs.

`scripts/m5stack_qemu_boot.bash` (repo root) fetches Espressif's prebuilt
`qemu-xtensa` release, merges the firmware's `bootloader.bin`/
`partitions.bin`/`firmware.bin` into one flash image with `esptool.py
merge_bin`, and boots it:

```sh
cd app/m5stack && pio run -e m5stack
cd .. && ../../scripts/m5stack_qemu_boot.bash app/m5stack/.pio/build/m5stack
# (from the repo root: scripts/m5stack_qemu_boot.bash app/m5stack/.pio/build/m5stack)
```

For a rendered display frame, build a display-capable QEMU first
(`scripts/m5stack_qemu_build.bash`, see "Emulation: display support" below)
and point the boot script at it:

```sh
scripts/m5stack_qemu_build.bash /tmp/m5stack-qemu-build   # one-time, a few minutes
M5STACK_QEMU_BIN=/tmp/m5stack-qemu-build/build/qemu-system-xtensa \
M5STACK_DISPLAY_DUMP=/tmp/m5stack_display.ppm \
  scripts/m5stack_qemu_boot.bash app/m5stack/.pio/build/m5stack
```

**Reaches `setup()` and `loop()` for real** -- verified by grepping the real
`m5stack: setup complete` and `Keys: A B C` lines out of the QEMU serial
log, not just a boot banner. Getting there needed one real fix, not just a
QEMU invocation: build Arduino as an ESP-IDF component
(`framework = arduino, espidf`, this project's actual `platformio.ini`
setting) rather than PlatformIO's default precompiled-Arduino-libs mode,
whose static libraries hit a real assert in their own SPI flash re-probe
under this exact QEMU release (`do_core_init`,
`esp_flash_init_default_chip() != ESP_OK`) that the from-source build does
not -- see the ADR's "Status, revised" section for the full, initially-wrong
-then-corrected investigation (it first looked like an ESP-IDF version gap;
it wasn't -- both paths use the same 4.4.7).

## Emulation: display support

Upstream `espressif/qemu` models no SPI TFT panel at all (checked directly
against `hw/display`) -- so this fork carries its own downstream addition,
`app/m5stack/qemu/patches/m5stack-display.patch`
(`scripts/m5stack_qemu_build.bash` builds a QEMU binary with it applied; see
that script's own header comment for the full rationale). It adds a new
`hw/display/esp32_ili9341.c` device modelled on this repo's own Renode
peripheral (`app/wio/renode/peripherals/Video/ILI9341_SPI.cs`), wired onto
the ESP32 machine's VSPI (SPI3) CS0 with D/C on GPIO27 -- matching
`env:m5stack`'s own TFT_eSPI `build_flags`. Getting a real (non-garbled)
frame out of it needed one further, more interesting fix: a genuine
upstream bug in `hw/ssi/esp32_spi.c`, where a stale post-reset register
default caused a phantom extra byte to be silently prepended to every SPI
transaction whenever a driver (TFT_eSPI's ESP32 driver among them) never
uses the SPI controller's own command phase -- see the patch's own comment
for the full trace that pinned it down (a raw-byte capture, then a
standalone `fillScreen()`/`fillRect()` test firmware whose output was a
checkerboard of correct and byte-swapped colors until the fix landed).

`M5STACK_DISPLAY_DUMP=<path> scripts/m5stack_qemu_boot.bash ...` (with a
`M5STACK_QEMU_BIN` built as above) writes the ILI9341 framebuffer out as a
PPM on exit -- QEMU's own `screendump`/monitor commands cannot reach this
device (it lives inside the ESP32 SoC's own private bus, never attached to
the real default sysbus; see `esp32_ili9341.c`'s own comment in the patch),
so this is a plain `atexit()` hook instead. The bring-up firmware's actual
LVGL "Keys: A B C" label renders correctly this way: a majority-white
background with real anti-aliased text pixels, not a blank or garbled
frame -- exactly what `.github/workflows/build.yml`'s `m5stack-qemu` job
checks on every run.

## What the emulator still cannot show

Button *input* injection: QEMU's ESP32 machine models no GPIO-injection
device (checked directly against `hw/gpio` in `espressif/qemu`; this fork's
own patch only extends the existing GPIO model's *output* side, needed for
the display's D/C line, not input), so a real button press stays out of
reach -- all three buttons read "pressed" under QEMU, since their GPIOs are
simply unconnected rather than driven, an accurate reflection of nothing
being wired to them rather than a bug. `main.cxx`'s status screen is
echoed over Serial for the same underlying reason display support used to
apply to: a QEMU boot verifies the firmware reaches `loop()` and reacts to
input, independently of whatever the display shows.
