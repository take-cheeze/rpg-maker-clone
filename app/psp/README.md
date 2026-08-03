# PSP EBOOT

A pspdev/CMake target that runs the RPG2k runtime on the Sony
[PlayStation Portable](https://en.wikipedia.org/wiki/PlayStation_Portable)
(Allegrex: MIPS32 R4000 @ 222/333 MHz, ~24 MB usable RAM, 480×272 LCD, D-pad +
analog stick + ✕○△□/L/R/Start/Select, Memory Stick).

This is additive to and independent of the desktop CMake build — building the
EBOOT does not touch the desktop/wasm builds, and vice versa. The design is in
[`docs/adr/0010-psp-port.md`](../../docs/adr/0010-psp-port.md).

## Status: HAL bring-up

This CMake project builds a **hardware bring-up EBOOT**: it stands up the LVGL
display over the LCD and reads the pad, without the mruby interpreter. It is the
first slice of the roadmap in the ADR and exists to prove the HAL compiles and
runs on the console (and to get real EBOOT size numbers from CI).

What runs today:

- `mruby-rgss/src/psp.cxx` — the HAL: an LVGL v9 display in **partial** render
  mode flushing to the 480×272 framebuffer via `sceDisplay` (accounting for the
  512-pixel line stride); the LVGL tick/delay source from the pspsdk system
  timer; and a scan of the D-pad, analog stick and ✕○△□ buttons into a bitmask.
- `app/psp/main.cxx` — a pspsdk sketch (module metadata + HOME-exit callback)
  that draws a status screen and echoes the pressed keys. `main()` owns the loop
  and pumps LVGL once per iteration, mirroring the Emscripten and Wio builds.
- `app/psp/lv_conf.h` — a PSP-tuned LVGL config (RGB565, a few-MB heap, no SIMD
  asm).

## Building

Requires the [pspdev toolchain](https://github.com/pspdev/pspdev) with `$PSPDEV`
set (it provides `psp-gcc`, the CMake toolchain file and `create_pbp_file`):

```sh
cmake -S app/psp -B build-psp \
  -DCMAKE_TOOLCHAIN_FILE=$PSPDEV/psp/share/pspdev.cmake
cmake --build build-psp          # -> build-psp/EBOOT.PBP
```

Run `EBOOT.PBP` under an emulator such as
[PPSSPP](https://www.ppsspp.org/), or copy it to
`PSP/GAME/rpg2k/EBOOT.PBP` on a Memory Stick (a homebrew-enabled console).

The bring-up writes two markers via `sceIoWrite` — `RPG2K_PSP_BOOT` once at
startup (a libc-free string literal) and `RPG2K_PSP_BRINGUP frame=N` once a
second. CI's `psp-smoke` job boots the EBOOT under PPSSPP headless and checks
that a marker appears, so a regression that links but fails to boot is caught
automatically. The job is **non-blocking**: PPSSPP only partially implements
pspsdk's libc stdio (plain `printf` is an unimplemented HLE import there), so
emulator capture can be fragile — the required build gate is the `psp` job. To
reproduce locally, run PPSSPP's headless binary with `--log` (needed to surface
the `sceIoWrite` output):

```sh
PPSSPPHeadless --log --graphics=software --timeout=15 EBOOT.PBP
```

## Not yet wired (later slices)

The pieces below are scaffolded but **not** part of the bring-up EBOOT:

- **mruby interpreter + game.** `mruby-rgss/src/psp_input_bridge.cxx` already
  translates the pad bitmask into `RGSS::Input` press/release events
  (`rgss_psp_poll`, called from `Graphics.update`), and `build_config.rb` has a
  `psp` mruby MIPS cross-build (`MRUBY_TARGET=psp`). Wiring `libmruby.a` into the
  EBOOT link and starting the real `RPG2k` scene tree is the next slice.
- **Memory-Stick assets.** Game data is opened by path through mruby-io /
  `std::fopen`; on the PSP these resolve to newlib syscalls backed by the
  Memory Stick, which pspsdk's `stdio` already routes. Pointing `GAME_DIR` at a
  project on the stick follows once mruby is linked.
- **Accelerated rendering.** The bring-up flushes with a CPU `memcpy` into the
  framebuffer. Moving the blit onto the `sceGu` GPU is a later optimisation.
