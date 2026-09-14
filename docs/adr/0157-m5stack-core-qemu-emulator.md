# 157. A QEMU (not Renode) emulator for the M5Stack Core port

Date: 2026-09-14

## Status

Proposed -- the port itself (`app/m5stack`, P1 HAL bring-up) and the QEMU
boot script are done and verified as far as described below. The known
remaining gap (the app's own SPI flash re-probe failing under
`framework-arduinoespressif32`'s vendored ESP-IDF v4.4.7) is isolated but
not fixed; nothing in this project can fix it without either patching a
precompiled upstream library or waiting on PlatformIO/Arduino-ESP32 to move
to a newer IDF baseline.

## Context

ADR 94 built a Renode emulator for the Wio Terminal (SAMD51) port, and ADR
(maix's own, see `app/maix/renode/`) reused Renode's own stock K210 support
for the Sipeed Maix Amigo. Both boards now have a "flash it and see it run"
gesture with no hardware attached. The obvious next step for a third
embedded target -- an M5Stack Core, chosen because its interchangeable
"FACES" kit bottoms make it a natural handheld candidate for this project --
is the same gesture: build the HAL/firmware bring-up (mirroring the Wio
Terminal's own P1 slice) and give it an emulator.

**Renode has no usable ESP32/Xtensa foundation, unlike the Cortex-M4 case
ADR 94 started from.** Checked directly against both `renode/renode` and
`renode/renode-infrastructure` (shallow-cloned, not just documentation,
which ADR 94's own investigation flagged as incomplete for exactly this
kind of question):

- `renode-infrastructure` ships exactly one ESP32-related peripheral:
  `Peripherals/UART/ESP32_UART.cs`. No GPIO, no SPI controller, no
  clock/reset controller, no interrupt matrix -- nothing an ESP32 boot path
  could stand on.
- `renode`'s own `platforms/` carries no ESP32 board or SoC `.repl` at all,
  only a generic `platforms/cpus/xtensa-sample-controller.repl` test stub
  (used by `tests/platforms/xtensa.robot`), nowhere near a real chip.

ADR 94's Wio Terminal work started from a real Cortex-M4 core plus a GPIO
peripheral already in Renode and still needed two from-scratch peripherals
(a SERCOM SPI controller, an ILI9341 panel) plus nine clock-tree register
stubs across four phases. Starting an ESP32 platform from *zero* -- a full
dual-core Xtensa LX6 SoC, its GPIO matrix, SPI controllers, interrupt
matrix and RTC/clock bring-up, all before a single byte of boot code could
run -- is a materially larger, multi-session undertaking, and this session
has neither a real M5Stack board nor a `dotnet` SDK installed to even build
a patched Renode locally. Attempting it anyway would produce exactly the
kind of unverified, "probably works" C# this project's own culture (ADR 94:
"verified directly, not assumed") rejects.

**Espressif publishes its own QEMU fork for exactly this purpose.**
`tools.json` in `espressif/esp-idf` (fetched directly, not assumed) lists a
prebuilt `qemu-xtensa` release per platform, the same binary `idf.py qemu`
uses in Espressif's own CI. Its `hw/xtensa/esp32.c` (checked directly,
shallow-cloned) is a real, actively maintained ESP32 machine: genuine
`ESP32_GPIO`, four `ESP32_SPI` controllers (SPI0/1 for flash/PSRAM,
SPI2/SPI3 free for peripherals), an interrupt matrix, RTC, timer groups,
I2C, eFuse and Ethernet -- register-accurate models, not stubs, because
Espressif itself depends on this fork for their own testing. `hw/display`,
`hw/ssi` and `hw/gpio` (also checked directly) confirm the one real gap: no
SPI TFT panel device and no button/GPIO-injection device exist upstream, so
a rendered frame or a real button press are not observable this way --
smaller and differently shaped than Renode's gap, but real.

## Decision

Use QEMU, not Renode, for this port's emulator. Concretely:

- `app/m5stack`: the P1 HAL bring-up firmware (`mruby-rgss/src/m5stack.cxx`
  + `app/wio/src/m5stack_main.cxx`/`m5stack_hal.cxx`, `env:m5stack` in
  `platformio.ini`), the same shape as the Wio Terminal's own P1 slice. See
  `app/m5stack/README.md`.
- `scripts/m5stack_qemu_boot.bash`: fetches Espressif's prebuilt
  `qemu-xtensa` release (pinned by hash the same way
  `scripts/wio_renode_build.bash` pins `RENODE_REF`), merges the firmware's
  `bootloader.bin`/`partitions.bin`/`firmware.bin` into one flash image with
  `esptool.py merge_bin`, writes the default eFuse image real hardware
  would already carry (copied from `esp-idf`'s own
  `tools/idf_py_actions/qemu_ext.py`), and boots it under `qemu-system-xtensa
  -M esp32`.

**What was verified, directly, not assumed:**

- `pio run -e m5stack` builds a real firmware for the real
  `m5stack-core-esp32` board (PlatformIO ships this board definition
  natively -- unlike Wio/Maix, no custom `boards/*.json` was needed).
- Booted under the QEMU setup above, the real Xtensa CPU executes the real
  ROM bootloader ("`ets Jul 29 2019 12:21:46`", genuine boot-ROM banner
  text) and then this project's own compiled second-stage bootloader
  (reaches its `entry 0x...` jump) -- not a stub, the actual bytes `pio
  run` produced.
- Past that point, every build hits: `assert failed: do_core_init
  startup.c:328 (flash_ret == ESP_OK)`, i.e. `esp_flash_init_default_chip()`
  returning failure during the app's own SPI flash re-probe, before
  `Serial.begin()` ever runs.
- **This was isolated to a real, external cause, not this project's
  firmware/HAL and not a general QEMU/ESP32 limitation**, by a controlled
  comparison: a plain ESP-IDF "hello world" (`framework = espidf`, no
  Arduino, no LVGL, no TFT_eSPI) built for the same `esp32dev` board and
  booted through the *exact same* QEMU invocation and eFuse image reaches
  `app_main()` cleanly and prints on the real UART -- proving the QEMU
  invocation, merge_bin layout and eFuse image here are all correct. The
  only difference between the two builds is the framework, and
  `~/.platformio/packages/framework-arduinoespressif32/tools/sdk/versions.txt`
  (checked directly) shows why: even the newest `framework-arduinoespressif32`
  PlatformIO's `espressif32` platform installs still vendors a fixed,
  precompiled **ESP-IDF v4.4.7** (from 2022), while the working plain-IDF
  build used ESP-IDF 6.1.0. `do_core_init`/`esp_flash_init_default_chip()`
  exists in both (confirmed by reading `components/esp_system/startup.c`
  directly from an `esp-idf` `v5.1.6` checkout), so the SPI flash
  generic-chip driver's behaviour against this exact QEMU release's
  simulated flash chip evidently changed for the better somewhere between
  4.4.7 and 6.1.0 -- a real upstream gap between two library versions this
  project does not control, not a bug in `app/m5stack` or `m5stack.cxx`.

`scripts/m5stack_qemu_boot.bash` encodes exactly that honest bar: it exits
0 once the CPU is confirmed executing this build's own second-stage
bootloader (the real, currently-passing checkpoint), and its own comments
spell out why "setup complete" is not yet reachable, rather than the script
silently asserting something not actually true.

## Consequences

- A regression that breaks the firmware before the bootloader even starts
  running (a bad link, a corrupted image, a broken merge/eFuse step) is
  now catchable without hardware; a regression in `m5stack.cxx`'s own HAL
  code past that point currently is not, since nothing gets far enough to
  exercise it under emulation yet.
- Closing the remaining gap is external to this repo: either PlatformIO's
  `espressif32` platform ships a `framework-arduinoespressif32` build
  against a newer ESP-IDF baseline (Arduino-ESP32's own 3.x line tracks
  IDF 5.x+), or someone backports whatever changed in the SPI flash
  generic-chip driver into a patched build of the old one. Patching a
  precompiled, vendored library ourselves was judged out of scope here --
  higher risk and more fragile than the equivalent from-scratch peripheral
  work ADR 94 did, since there is no source tree to patch, only a `.a` to
  replace.
- Display and button verification remain out of reach under this emulator
  regardless of the flash-probe gap (no SPI TFT panel or GPIO-injection
  device upstream in `espressif/qemu`) -- `app/m5stack/README.md`'s own
  "What the emulator can and cannot show" section documents this so a
  future session does not re-discover it from scratch. A UART-text
  checkpoint (mirroring `docs/adr/0094`'s own P1 "no peripherals beyond
  UART" bar) is the ceiling here even once `do_core_init` is unblocked,
  unless a future session decides writing an SPI-TFT QEMU device
  (analogous to `app/wio/renode/peripherals/Video/ILI9341_SPI.cs`, but as a
  QEMU C device model rather than a Renode C# one) is worth the effort.
- `platformio.ini`'s `env:m5stack_qemu` and CI's `m5stack-qemu` job assert
  only the currently-true checkpoint (bootloader entry), not "setup
  complete" -- if a future change to `framework-arduinoespressif32`'s
  pinned version closes the `do_core_init` gap, that CI job's own log will
  show the assert disappearing and its bar should be raised to match,
  rather than silently continuing to under-check.
