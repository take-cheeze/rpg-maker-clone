# 157. A QEMU (not Renode) emulator for the M5Stack Core port

Date: 2026-09-14

## Status

Accepted -- the port (`app/m5stack`, P1 HAL bring-up) and the QEMU boot
script both work end to end: `scripts/m5stack_qemu_boot.bash` boots the real
firmware under a real ESP32 machine and reaches `setup()`/`loop()`,
verified by grepping the real `m5stack: setup complete` and `Keys: ...`
lines out of the real UART log. Getting there needed the port to build
Arduino as an ESP-IDF component rather than PlatformIO's default
precompiled-Arduino mode -- see "Status, revised" below for the full,
initially-wrong-then-corrected investigation.

## Context

ADR 94 built a Renode emulator for the Wio Terminal (SAMD51) port, and Maix
Amigo (`app/maix/renode/`) reuses Renode's own stock K210 support. Both
boards have a "flash it and see it run" gesture with no hardware attached.
The obvious next step for a third embedded target -- an M5Stack Core,
chosen because its interchangeable "FACES" kit bottoms make it a natural
handheld candidate for this project -- is the same gesture: build the
HAL/firmware bring-up (mirroring the Wio Terminal's own P1 slice) and give
it an emulator.

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
run -- would be a materially larger, multi-session undertaking, and this
session has neither a real M5Stack board nor a `dotnet` SDK installed to
even build a patched Renode locally.

Two other ESP32 emulators were suggested and checked directly, not just by
name:

- `espressif/esp-emulator`: a real, official Rust-based CPU emulator --
  but RISC-V only (C3/C5/C6/H2/P4/S31, per its own README). The M5Stack
  Core is the original Xtensa LX6 ESP32; not covered at all.
- `quantumnic/esp32emu`: not a CPU/hardware emulator -- a host-native mock
  of Arduino/ESP-IDF APIs you recompile a sketch against (same category as
  this project's own `app/nano7/host`, not `app/nano7/qemu`). A single-
  commit, ~10-day-old, one-author repo with an implausibly broad feature
  claim for its age; its `TFT_eSPI.h` mock (checked directly) does not even
  implement the `pushColors`/`setAddrWindow`/`startWrite`/`endWrite` calls
  `m5stack.cxx`'s flush callback uses. Not a fit.

**Espressif publishes its own QEMU fork for the real Xtensa ESP32.**
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
smaller and differently shaped than Renode's gap, but real (see
`app/m5stack/README.md`'s "What the emulator can and cannot show").

## Decision

Use QEMU, not Renode, for this port's emulator. Concretely:

- `app/m5stack`: a **standalone PlatformIO project** (its own
  `platformio.ini`, not another environment in the repo root's), the P1 HAL
  bring-up firmware (`mruby-rgss/src/m5stack.cxx` + `src/main.cxx`/
  `m5stack_hal.cxx`). See `app/m5stack/README.md` for why it is standalone
  rather than sharing the root file the way Wio/Maix do -- summary: its
  build mode (below) needs the project root's own `CMakeLists.txt`, which
  would collide with the repo's real desktop CMake build if it lived there.
- `scripts/m5stack_qemu_boot.bash` (repo root): fetches Espressif's
  prebuilt `qemu-xtensa` release (pinned by hash the same way
  `scripts/wio_renode_build.bash` pins `RENODE_REF`), merges the firmware's
  `bootloader.bin`/`partitions.bin`/`firmware.bin` into one flash image with
  `esptool.py merge_bin`, writes the default eFuse image real hardware
  would already carry (copied from `esp-idf`'s own
  `tools/idf_py_actions/qemu_ext.py`), and boots it under `qemu-system-xtensa
  -M esp32`.

### Status, revised: the flash-probe assert, and how it was actually fixed

The first pass at this ADR used PlatformIO's default Arduino integration
(`framework = arduino`, precompiled static libs) and hit a real, reproducible
assert on every boot, past a real ROM bootloader and this project's own
compiled second-stage bootloader:

```
assert failed: do_core_init startup.c:328 (flash_ret == ESP_OK)
```

i.e. `esp_flash_init_default_chip()` failing during the app's own SPI flash
re-probe, before `Serial.begin()` ever ran. Two rounds of controlled,
direct verification chased this down, and the first round's own conclusion
turned out to be incomplete:

1. **Ruled out this script's own QEMU/merge_bin/eFuse setup.** A plain
   ESP-IDF "hello world" (`framework = espidf`, no Arduino at all) built for
   the generic `esp32dev` board and booted through the *exact same* QEMU
   invocation and eFuse image reached `app_main()` cleanly. The unpinned
   `framework-espidf` package PlatformIO installed for that test turned out
   to be ESP-IDF 6.1.0 (`esp_idf_version.h`, checked directly) -- a much
   newer baseline than Arduino's. **This is the round that led an earlier
   version of this ADR to (wrongly) conclude the fix had to be upstream**,
   in either PlatformIO shipping a newer Arduino-ESP32 core or an IDF
   backport.
2. **That conclusion was corrected by actually trying the combination
   PlatformIO already documents for exactly this**: `framework = arduino,
   espidf` -- "Arduino as an ESP-IDF component" -- builds Arduino from
   source as a component of a real ESP-IDF project, instead of linking
   `framework-arduinoespressif32`'s precompiled static libraries. The
   package PlatformIO resolves for this mode is
   `framework-espidf@3.40407.240606`, whose own `esp_idf_version.h` (checked
   directly) is **still ESP-IDF 4.4.7** -- the same version the precompiled
   libs use. Built this way and booted under the identical QEMU/eFuse setup,
   **the assert does not happen**: `spi_flash: detected chip: gd` succeeds,
   and the firmware reaches `app_main()`, `setup()`, and `loop()`.

So the fault was never the IDF version at all -- both paths use 4.4.7. It is
specific to `framework-arduinoespressif32`'s **precompiled** static
libraries (`tools/sdk/esp32/lib/*.a`) versus building the identical source
fresh as a component: something about how those particular archives were
built (most likely a baked-in flash-mode/SPI-config assumption mismatched
against this QEMU release's simulated flash chip) makes the precompiled
`libspi_flash.a` fail a probe that an otherwise-identical from-source build
does not. This was not chased further into the precompiled library's own
build inputs -- once a working, supported PlatformIO build mode existed,
diagnosing exactly which archive-level difference triggers it stopped being
worth the additional certainty, per this project's usual "verified enough
to act on, not necessarily to the last percent" bar.

Two real, load-bearing costs of `arduino, espidf` mode, both hit directly
and fixed, not just documented from PlatformIO's own docs:

- **PlatformIO's ESP-IDF/CMake build mode takes over the *project root's*
  own `CMakeLists.txt`** (and auto-generates one if absent) and **cannot
  honor `build_src_filter`** at all (`pio run` prints
  `Warning: the 'src_filter' option cannot be used with ESP-IDF` and pulls
  in every file under the project's source directory as one component).
  Both are fatal to sharing the repo root's own `platformio.ini`/
  `CMakeLists.txt`/`src_dir` the way Wio and Maix do -- the first would
  collide with the real desktop SDL2 CMake build sitting at the repo root,
  the second would pull `wio`/`wio_walk`/`maix_amigo`/etc.'s own sources
  (each defining their own conflicting `setup()`/`app_main`) into the same
  build. Hence `app/m5stack` being its own standalone PlatformIO project.
- **This mode does not auto-generate the `app_main()` entry point** the way
  plain `framework = arduino` does. `src/main.cxx` writes it by hand:
  `extern "C" void app_main(void) { initArduino(); setup(); while (true)
  loop(); }`.
- `framework-arduinoespressif32`'s own `CMakeLists.txt` hard-errors unless
  `CONFIG_FREERTOS_HZ=1000` (the espidf framework's own default is 100), and
  the espidf framework's own default flash size (2 MB) does not match this
  board's real 4 MB -- both set in `app/m5stack/sdkconfig.defaults`, the
  ESP-IDF mechanism for project-level Kconfig overrides (a `custom_sdkconfig`
  platformio.ini key does not exist in this platform version's builder --
  checked directly against `~/.platformio/platforms/espressif32/builder/frameworks/espidf.py`
  before landing on the right mechanism).

`scripts/m5stack_qemu_boot.bash` asserts the real, now-true bar: it exits 0
once the log contains both `m5stack: setup complete` and a `Keys: ...` line
-- the firmware's own display+button HAL actually ran, not just "the CPU is
doing something."

## Consequences

- A regression that breaks the firmware anywhere from bootloader through
  `m5stack.cxx`'s HAL init and the first button scan is now catchable in CI
  without hardware -- not just a link-level check the way the pre-Renode
  `wio` job originally was.
- Display and button *rendering* verification remain out of reach under
  this emulator regardless (no SPI TFT panel or GPIO-injection device
  upstream in `espressif/qemu`) -- `app/m5stack/README.md`'s own "What the
  emulator can and cannot show" section documents this so a future session
  does not re-discover it from scratch. A UART-text checkpoint (mirroring
  `docs/adr/0094`'s own P1 "no peripherals beyond UART" bar) is the ceiling
  here, unless a future session decides writing an SPI-TFT QEMU device
  (analogous to `app/wio/renode/peripherals/Video/ILI9341_SPI.cs`, but as a
  QEMU C device model rather than a Renode C# one) is worth the effort.
- `app/m5stack` being a second, standalone PlatformIO project (rather than
  another environment in the repo root's `platformio.ini`) is a new shape
  for this repo's embedded ports. A future port that also needs
  `framework = ..., espidf` (or any other ESP-IDF/CMake-based framework)
  will hit the same root-`CMakeLists.txt`/`build_src_filter` conflict and
  should follow the same standalone-project shape rather than trying to
  force it into the shared file again.
- Reusing `app/wio/exclude_lvgl_asm.py` (LVGL's Helium/NEON `.S` kernels
  need excluding on every target this repo has, ARM Cortex-M4 included)
  from a second project root surfaced a real latent bug in it, not just an
  M5Stack-specific wrinkle: its glob was relative to the *invoking*
  project's CWD, which happened to equal the repo root for Wio/Maix but not
  for `app/m5stack`, so it silently matched zero files there (no error --
  just the exact assembler failure it exists to prevent, further disguised
  because a prior SCons build's already-deleted `.S` files in the shared
  submodule checkout made an early version of this port's own build appear
  to pass). Fixed by walking up from `$PROJECT_DIR` to find `3rd/lvgl/src`
  rather than assuming a fixed relative depth or an already-correct CWD --
  verified against both project roots, not just the new one.
- The precompiled-vs-from-source Arduino library discrepancy itself was not
  root-caused at the archive/build-config level -- if a future session
  needs `framework = arduino` (plain, precompiled) to work under this QEMU
  release too (e.g. for a firmware too large or slow to build as a full
  ESP-IDF-from-source project every time), that investigation still needs
  doing.
