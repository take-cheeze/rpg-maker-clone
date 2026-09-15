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
one, so `include/m5stack.hxx`'s `M5Key` enum only ever sets the A/B/C bits
from the Core's own front buttons; Up/Down/Left/Right depend entirely on
an attached M5Stack FACES kit Gamepad Face -- see "Gamepad Face (FACES
kit)" below -- and stay unset with none attached, the same way this HAL
leaves them (see that header's own comment). Mapping buttons onto a usable
RPG movement scheme is a real product design question for a later slice,
not something this HAL-only bring-up firmware answers.

```sh
cd app/m5stack
pio run -e m5stack            # compile the bring-up firmware
pio run -e m5stack -t upload  # flash a connected M5Stack Core
```

No mruby interpreter or RGSS scene tree yet -- those are later slices, the
same progression the Wio/Maix ports followed (HAL bring-up first, then link
`libmruby.a`, then real assets). The microSD slot itself is up (see
"Audio" below), but only for this one HAL-level WAV-playback primitive --
a general SD-backed game-asset pipeline (`RGSS::Audio`, `Bitmap` image
loading, the RGSSAD archive reader) is a separate, later piece of work.

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

## Gamepad Face (FACES kit)

The M5Stack FACES kit's Gamepad Face ("Game Face", MEGA328-based, one of
the kit's interchangeable bottom modules alongside the QWERTY keyboard and
calculator faces) is an I2C device at address 0x08 on the Core's internal
I2C bus (`Wire`, SDA=GPIO21/SCL=GPIO22) -- a real, optional add-on this HAL
now supports, not a fixed part of the Core itself. Protocol verified
directly against the module's own real firmware
(github.com/m5stack/FACES-Firmware, `GameBoy.ino`, read from source, not
assumed from marketing copy): every I2C read returns one byte, the AVR's
live `PORTB` snapshot, active low, one bit per button (Up/Down/Left/Right/
A/B/Select/Start). `m5stack_input_init()` probes address 0x08 once at
boot; with no Face attached, the probe just NACKs and every subsequent
scan skips it entirely -- see `m5stack_input_scan()`'s own doc comment in
`include/m5stack.hxx` for the full bit layout and how it folds into the
existing bitmask (the Face's own D-pad and A/B feed the same bits the
Core's own buttons do; Select/Start, having no RGSS button of their own,
land on the spare `M5_INPUT_N0`/`N1` ids -- the same convention
`include/psp.hxx`'s own comment documents for the PSP port's spare
buttons).

Emulated the same way the display is: `espressif/qemu` has a real,
register-accurate ESP32 I2C controller (`hw/i2c/esp32_i2c.c`) already
wired to a `tmp105` sensor for this exact machine
(`esp32_machine_init_i2c()`), so `app/m5stack/qemu/patches/
m5stack-gamepad.patch` (also applied by `scripts/m5stack_qemu_build.bash`)
just attaches one more device to that same bus:
`hw/i2c/esp32_faces_gamepad.c` models the Gamepad Face's own protocol
above. Unlike the display (an *output* observability problem, solved with
an `atexit()` dump), simulating a button press is an *input* problem: this
device re-reads a single raw byte from `ESP32_FACES_GAMEPAD_STATE_PATH`
(env var) on every I2C read, if set, so state can change while QEMU runs.
`scripts/m5stack_qemu_boot.bash`'s own `M5STACK_GAMEPAD_STATE` env var
wraps this for one fixed combination held for a whole boot:

```sh
M5STACK_QEMU_BIN=/tmp/m5stack-qemu-build/build/qemu-system-xtensa \
M5STACK_GAMEPAD_STATE=7e \
  scripts/m5stack_qemu_boot.bash app/m5stack/.pio/build/m5stack
# 0x7e = Up + Start held (active low, bit0 and bit7 clear)
```

The firmware's own `Keys: ...` line shows `Up` and `Start` alongside the
Core's own always-"held" `A B C` this way -- verified end to end (real I2C
probe, real read, real bit decode, real RGSS-key mask, real status line),
not just that the emulated device itself returns the right byte in
isolation -- exactly what `.github/workflows/build.yml`'s `m5stack-qemu`
job checks on every run.

## Audio

The Core's built-in speaker plays WAV files off the microSD slot:
`m5stack_audio_init()` mounts the card, and `m5stack_audio_play_wav(path)`
opens, parses and plays one file, blocking until it finishes. `src/main.cxx`'s
demo triggers both on a fresh press of a FACES Gamepad Face's Start button
(see "Gamepad Face" above) -- deliberately not one of the Core's own front
buttons, which read "held" for the entire run under the QEMU smoke test and
would fire this on every single boot -- and deliberately lazily (on that
first press, not unconditionally from `setup()`): see `m5stack_audio_init()`'s
own doc comment in `include/m5stack.hxx` for why (a real shared-VSPI-bus
hazard on top of a QEMU-only display-model gap, both below).

Both the SD slot and the speaker's wiring were checked directly, not
assumed from a generic ESP32 pinout: the microSD slot shares the display's
own SPI bus (`SD.begin(4)` -- CS=GPIO4, the same SCK=18/MISO=19/MOSI=23
TFT_eSPI's own `build_flags` already configure the LCD on) rather than a
separate bus, confirmed against M5Stack's own community documentation of
the Basic/Gray board; the speaker amplifier is wired to GPIO25, one of the
ESP32's two internal 8-bit DAC channels, which `m5stack_audio_play_wav()`
drives directly with `dacWrite()` -- no I2S DMA yet, so this is a **blocking,
timer-free** player (`delayMicroseconds()` paced against the file's own
declared sample rate), not something a real game loop could call without
stalling LVGL and button scanning for the file's whole duration. A
non-blocking, I2S-driven version is future work, not part of this first cut.

Understands uncompressed PCM WAV only (8 or 16-bit, mono or stereo, any
declared sample rate) -- downmixed to mono and rescaled to 8-bit unsigned
for the DAC. RPG Maker's other BGM formats (OGG, MP3, MIDI) need a real
decoder library this tree does not currently vendor (checked directly:
`3rd/` has none, and the obvious Arduino-ecosystem choice,
[ESP8266Audio](https://github.com/earlephilhower/ESP8266Audio), decodes
Opus-in-Ogg but not Ogg Vorbis, which is what RPG Maker VX/VX Ace's own RTP
BGM assets actually are) -- out of scope here.

**Verification boundary, stated plainly rather than overclaimed:** the WAV
chunk-parsing (including skipping an unrecognised chunk like `LIST` before
`data`, and rejecting a non-WAV file) and the 16-bit-to-8-bit/stereo-downmix
math are verified correct against known values in a standalone host-side
test (no board or emulator involved) -- signed-16 min/max/zero-crossing
cases and 8-bit passthrough/averaging all land exactly where the math says
they should. The firmware itself builds for real hardware and boots safely
under QEMU with no SD card attached at all (`SD.begin()` fails cleanly, no
hang, `setup()` still completes) -- but two more QEMU-specific gaps turned
up chasing that down to a real display-dump comparison, not just a
"still boots" glance, both worth stating plainly rather than glossing over:

- `SD.begin()` unconditionally calls the Arduino `SPIClass`'s own
  `spi.begin()`, which only no-ops if *that exact C++ object* was already
  started; TFT_eSPI keeps its own private `SPIClass` bound to the same
  physical VSPI peripheral the display uses, so the naive `SD.begin(4)`
  handed it a second, fresh `SPIClass` and genuinely reset that peripheral's
  hardware registers out from under TFT_eSPI -- confirmed directly against
  a QEMU display dump (mostly garbled colors instead of the intended black
  background). Fixed by passing `g_tft.getSPIinstance()` to `SD.begin()`
  instead of the implicit default.
- Even with that fix, a QEMU-only display-model gap remains: this fork's
  emulated ILI9341 does not gate on the real `TFT_CS` pin the way real
  silicon does, so *any* SPI traffic on the shared bus -- including a plain
  SD card probe addressed to its own, different CS line -- still reaches
  the display model and corrupts it. Confirmed by testing with `SD.begin()`
  called both from `setup()` (before the demo ever draws anything -- no
  corruption observed) and later, from `loop()` gated behind a button press
  (corruption observed) -- isolating this to the display model's own CS
  handling, not this PR's parsing or downmix code. This is *why*
  `m5stack_audio_init()` is called lazily rather than unconditionally at
  boot: the plain QEMU smoke test never presses Start, so it never touches
  SD at all, sidestepping this gap entirely (a real design improvement in
  its own right -- don't spin up a peripheral nothing has asked for -- not
  just a workaround).

A third, separate finding surfaced only in the *lazily-triggered* path and
is being disclosed rather than quietly worked around: pressing Start under
QEMU with a Gamepad Face attached (`M5STACK_GAMEPAD_STATE`) still reliably
reaches this firmware's own `"Keys: ... Start"` line -- the CI check this
repo actually runs -- but the SD mount failure that follows (no SD-over-SPI
device exists under QEMU at all, see below) then trips a FreeRTOS assertion
inside the Arduino SD library's own mount-failure cleanup path
(`assert failed: xQueueGenericSend`, inside `SPIClass::endTransaction()`),
rebooting the guest. Reproduces with the *default* global `SPI` object too
(not just `getSPIinstance()`), and with or without a Gamepad Face attached
-- calling `SD.begin()` from `setup()`, before anything else has run, never
triggers it; calling the identical function later, from `loop()`, does.
That "works early, breaks later" shape, on a call path (a global
`SPIClass`'s own mutex, created at C++ static-init time) that countless
real ESP32 Arduino sketches exercise this exact way without incident,
points at a QEMU-specific FreeRTOS/heap-timing artifact rather than a bug
in this PR's own code -- but it is *not independently confirmed* on real
hardware, unlike the two findings above, so it is flagged as suspected
QEMU-only, not proven. What is **not** verified: real analog output, which
needs actual hardware and a way to capture it that does not exist yet
(unlike the display, no downstream QEMU device models the DAC or LEDC-PWM
path this speaker could plausibly also use); and real SD-over-SPI file
access under QEMU -- tried directly and it does not work, not just
untried: `espressif/qemu`'s own SD card support (`esp32_machine_init_sd`,
already in the fork, no new patch needed) wires its `TYPE_SD_CARD` to the
ESP32's dedicated SDMMC peripheral, a genuinely different piece of hardware
from the SPI bus this board's real SD slot (and Arduino's `SD` library)
actually uses -- confirmed by attaching a real FAT-formatted SD image and
watching the ESP-IDF SD driver itself fail to select the card
(`sdSelectCard(): Select Failed`) even though the file/filesystem side was
correct. Bridging that gap (a `ssi-sd`-style SPI-mode SD device, the way
QEMU's own generic boards do it) is possible but is new QEMU work, out of
scope for this pass -- see `docs/adr/0157-m5stack-core-qemu-emulator.md`'s
own "Status, audio support" section.

## What the emulator still cannot show

The Core's own front A/B/C buttons stay unpressable: QEMU's ESP32 machine
models no GPIO-injection device (checked directly against `hw/gpio` in
`espressif/qemu`; this fork's own display patch only extends the existing
GPIO model's *output* side, needed for the display's D/C line, not input),
so those three -- plain GPIOs, not I2C -- always read "pressed" under
QEMU, since their GPIOs are simply unconnected rather than driven, an
accurate reflection of nothing being wired to them rather than a bug. A
Gamepad Face's own buttons do not have this limitation (see above), since
they arrive over I2C, a bus this fork's downstream QEMU device can
actually inject into. `main.cxx`'s status screen is echoed over Serial for
the same underlying reason display support used to apply to: a QEMU boot
verifies the firmware reaches `loop()` and reacts to input, independently
of whatever the display shows.
