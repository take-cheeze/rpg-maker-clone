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

## Status: P1 -- HAL bring-up (LVGL display + input, no mruby yet)

`pio run -e m5stack` builds a **bring-up firmware**: the same shape as
`env:wio`'s own P1 slice. `mruby-rgss/src/m5stack.cxx` (pulled in via the
`m5stack_hal.cxx` shim so it compiles without linking mruby, mirroring
`wio_hal.cxx`) stands up an LVGL display over the Core's ILI9341 through
[TFT_eSPI](https://github.com/Bodmer/TFT_eSPI) -- configured entirely by
`build_flags` in `platformio.ini` (pins, driver, SPI frequency), not a
checked-in `User_Setup.h` -- and scans the three A/B/C buttons into a
bitmask. `app/wio/src/m5stack_main.cxx` (living under `app/wio/src/` only
because `src_dir` in `platformio.ini` is project-wide, the same reason
`maix_amigo_main.cxx` lives there) draws a small status screen and echoes
pressed keys over Serial.

The Core has no built-in D-pad the way the Wio Terminal's 5-way switch is
one, so `include/m5stack.hxx`'s `M5Key` enum only ever sets the A/B/C bits;
Up/Down/Left/Right stay reserved and unbound (see that header's own comment).
Mapping three buttons onto a usable RPG movement scheme is a real product
design question for a later slice, not something this HAL-only bring-up
firmware answers.

```sh
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
`UART.ESP32_UART`, and a bare `xtensa-sample-controller.repl` test stub;
building a from-scratch Xtensa LX6 + ESP32 SoC the way the Wio Terminal ADR
built a SAMD51 platform would be a far larger, unverifiable-in-one-session
undertaking). **Espressif publishes its own QEMU fork instead** (the same
binary `idf.py qemu` uses), with a real, actively-maintained ESP32 machine
model (`hw/xtensa/esp32.c`): genuine GPIO, SPI, UART, RTC, timer and eFuse
peripherals, not stubs.

`scripts/m5stack_qemu_boot.bash` fetches Espressif's prebuilt `qemu-xtensa`
release, merges `env:m5stack`'s `bootloader.bin`/`partitions.bin`/
`firmware.bin` into one flash image with `esptool.py merge_bin`, and boots
it:

```sh
pio run -e m5stack
scripts/m5stack_qemu_boot.bash .pio/build/m5stack
```

**Current status: reaches the real Xtensa CPU executing this project's own
compiled second-stage bootloader, not yet "setup complete".** Every firmware
built against `framework-arduinoespressif32` (which vendors a fixed,
precompiled ESP-IDF **v4.4.7**) hits a real assert during the app's own SPI
flash re-probe (`do_core_init`, `esp_flash_init_default_chip() != ESP_OK`)
before `Serial.begin()` ever runs. This is isolated to that old vendored
IDF release, not this project's firmware/HAL, and not a general QEMU
limitation: a plain ESP-IDF 6.1.0 "hello world", built and booted through
the exact same QEMU invocation and eFuse image, reaches `app_main()` and
prints on the real UART without incident. See the ADR for the full
before/after comparison and what would need to change upstream to close the
gap.

## What the emulator can and cannot show

Even past that gap, QEMU's ESP32 machine models no SPI TFT panel and no
button GPIO injection -- genuinely missing upstream (checked against
`hw/display`, `hw/ssi`, `hw/gpio` in `espressif/qemu`), not a shortcut this
project took. `main.cxx`'s status screen is echoed over Serial for exactly
this reason (see its own comment), so once the flash-probe gap above closes,
a QEMU boot can still verify the firmware reaches `loop()` and reacts to
input from real Serial text, just not a rendered frame or a real button
press -- the same "UART only" bar the Wio Terminal Renode platform's own P1
phase set (`docs/adr/0094`), for the same reason.
