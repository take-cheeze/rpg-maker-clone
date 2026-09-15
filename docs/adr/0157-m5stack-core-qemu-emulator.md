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

A rendered display frame is also now reachable, not just the UART log: a
downstream QEMU patch (`app/m5stack/qemu/patches/m5stack-display.patch`,
built by `scripts/m5stack_qemu_build.bash`) adds the ILI9341 device
upstream `espressif/qemu` lacks and fixes a real upstream SPI-controller bug
that otherwise corrupted every frame -- see "Status, display support"
below.

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

### Status, display support: a real QEMU device and a real upstream bug

The original version of this ADR (and `app/m5stack/README.md`'s own "What
the emulator can and cannot show" section) documented display rendering as
out of reach: `espressif/qemu` genuinely models no SPI TFT panel (checked
directly against `hw/display`). A follow-up session closed that gap with a
downstream QEMU patch rather than accepting the gap as permanent --
`app/m5stack/qemu/patches/m5stack-display.patch`, built into a real binary
by `scripts/m5stack_qemu_build.bash` the same way
`scripts/wio_renode_build.bash` builds Renode from source with this repo's
two new peripherals. The patch:

1. Adds `hw/display/esp32_ili9341.c`, a new SSI-peripheral device modelled
   directly on this repo's own Renode peripheral
   (`app/wio/renode/peripherals/Video/ILI9341_SPI.cs`): it interprets only
   CASET/PASET/RAMWR (everything else is consumed with no effect, same
   scope decision the Renode model made) and renders into a QEMU
   `QemuConsole`.
2. Extends `hw/gpio/esp32_gpio.c`, previously a near-stub that only ever
   implemented reading back the `GPIO_STRAP` register, to actually track
   and drive its output pins (`GPIO_OUT`/`GPIO_OUT_W1TS`/`GPIO_OUT_W1TC`
   and the pins-32-39 `GPIO_OUT1` family) -- needed for the display's D/C
   (data/command) line, which real ILI9341 hardware drives from a plain
   GPIO rather than the SPI byte stream itself.
3. Wires the new device onto the ESP32 machine's VSPI (SPI3) controller at
   CS0, with D/C on GPIO27 -- matching `env:m5stack`'s own TFT_eSPI
   `build_flags` in `platformio.ini` exactly, not a value picked to make
   the emulator convenient.

**Verifying any of this needed solving an observability problem before a
correctness one.** QEMU's `screendump`/monitor device-lookup path
(`qemu_console_lookup_by_device_name` -> `qdev_find_recursive`) only walks
buses reachable from the real default sysbus, and `TYPE_ESP32_SOC` is a
plain `TYPE_DEVICE` realized directly (`qdev_realize(DEVICE(ss), NULL,
&error_fatal)`, never attached to `sysbus_get_default()`) -- confirmed
directly: `info qtree` under this machine only ever lists a handful of
`create_unimplemented_device()` stubs and `open_eth`, never the CPUs, the
SPI buses, or (once added) this display. Restructuring the SoC's whole bus
topology to fix that generically was judged out of scope for a downstream
addition, so `esp32_ili9341.c` instead registers a plain libc `atexit()`
hook: when `ESP32_ILI9341_DUMP_PATH` is set, the framebuffer is written out
as a PPM on process exit, which QEMU's own timeout-then-SIGTERM shutdown
(exactly what `scripts/m5stack_qemu_boot.bash` already does) still runs
normally. `scripts/m5stack_qemu_boot.bash`'s own `M5STACK_DISPLAY_DUMP` env
var wraps this.

**The first real frame this produced was uniformly black**, tracked down
through two distinct bugs, both confirmed rather than guessed at:

1. `ILI9341_WIDTH`/`ILI9341_HEIGHT` were initially set to the panel's native
   240x320 portrait memory layout. But this device does not interpret
   MADCTL (the same narrow-scope decision as the Renode peripheral), so it
   needs to hardcode the *logical*, post-rotation frame the firmware always
   draws in instead -- the M5Stack HAL's fixed `setRotation(1)`
   (`mruby-rgss/src/m5stack.cxx`). Swapped to 320x240 landscape; every
   CASET/PASET write had been failing a bounds check sized for the wrong
   axis until then.
2. Even after that fix, a standalone `fillScreen(RED)` +
   `fillRect(..., GREEN)` test firmware (built to isolate this from LVGL)
   still rendered as a checkerboard of correct and byte-swapped colors, not
   solid black -- progress, but still wrong. A raw SPI byte trace (a
   temporary debug build of `esp32_ili9341_transfer()`) showed the real
   cause was one level down the stack, not in this device at all: **every
   single byte of every SPI transaction -- command bytes, CASET/PASET
   parameters, RAMWR pixel data alike -- arrived with one extra `0x00` byte
   prepended.** Root-caused in `hw/ssi/esp32_spi.c`'s
   `esp32_spi_do_command()`: its `R_SPI_CMD_USR_MASK` case gated the SPI
   command phase on `SPI_USER.SPI_USR_COMMAND ||
   SPI_USER2.SPI_USR_COMMAND_BITLEN`, but `esp32_spi_reset_hold()` leaves
   `SPI_USER2.SPI_USR_COMMAND_BITLEN` at a nonzero post-reset default (4) --
   so any driver that addresses its device entirely through a GPIO D/C line
   and never uses the command phase at all (TFT_eSPI's ESP32 driver among
   them) still got a phantom one-byte command phase silently prepended to
   every transaction, because the stale register default alone satisfied
   the `||`. Per the ESP32 TRM, the enable bit is what should gate this,
   not the leftover bit-length field. Fixing the condition to check only
   `SPI_USER.SPI_USR_COMMAND` made both the standalone test firmware (exact
   pixel-for-pixel red/green match against the expected fill) and the real
   M5Stack HAL firmware (a correctly anti-aliased "Keys: A B C" LVGL label
   on a white background) render exactly right. This explains the earlier
   apparent "CASET/PASET deliver one extra leading byte" observation from
   this same investigation: it was never a CASET/PASET-specific quirk,
   just this same one-phantom-byte-per-transaction bug showing up on the
   4-byte address-phase writes those two commands happen to use.
   `esp32_ili9341_handle_window_byte()` keeps its rolling 4-byte shift
   register regardless (decoding "the last 4 bytes seen" rather than
   assuming exactly 4), since it costs nothing and stays correct even if a
   future SPI fix or a different driver's phase usage reintroduces extra
   leading bytes.
3. While in `esp32_spi.c`, `esp32_spi_txrx_buffer()`'s per-byte tx/rx-bound
   checks (`if (byte < tx_bytes)`) compared against `byte` -- always `0` at
   that point in the loop, not the loop index `i` -- rather than `if (i <
   tx_bytes)`. Fixed alongside the phantom-byte bug since it is in the same
   function and the same kind of latent correctness issue, though it does
   not affect any transaction shape this device or the existing flash-boot
   path actually uses (every call site here always has one of tx/rx at
   zero, so the wrong bound never changes behavior in practice).

`.github/workflows/build.yml`'s `m5stack-qemu` job now builds this patched
QEMU (cached the same way `wio-renode` caches its own from-source Renode
build) and checks the actual rendered framebuffer -- a majority-white
background plus real non-background (label text) pixels -- not just that a
dump file was produced.

## Consequences

- A regression that breaks the firmware anywhere from bootloader through
  `m5stack.cxx`'s HAL init and the first button scan is now catchable in CI
  without hardware -- not just a link-level check the way the pre-Renode
  `wio` job originally was.
- Display rendering verification is now reachable via a downstream QEMU
  patch (see "Status, display support" above) -- the SPI-TFT device this
  bullet originally proposed as future work, now written. Button *input*
  injection remains out of reach: `espressif/qemu` still models no
  GPIO-injection device (checked directly against `hw/gpio`; this fork's
  own patch only extends the existing GPIO model's output side, needed for
  the display's D/C line, not input), and `app/m5stack/README.md`'s "What
  the emulator still cannot show" section documents this so a future
  session does not re-discover it from scratch. All three buttons still
  read "pressed" under QEMU (their GPIOs are simply unconnected rather than
  driven, an accurate reflection of nothing being wired to them) -- a UART
  checkpoint remains the way `main.cxx`'s status screen content itself gets
  verified, independent of whatever the display shows.
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
