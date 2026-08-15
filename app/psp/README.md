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
  Its heartbeat also reports free device RAM and LVGL pool usage (see below).
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
startup (a libc-free string literal) and `RPG2K_PSP_BRINGUP
frame=N free=N maxfree=N lvgl_used=N lvgl_max=N` once a second, the last four
fields being `sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize` (the
device's actual free RAM) and `lv_mem_monitor`'s current/high-water-mark use
of LVGL's own pool — real numbers for
[ADR 0047](../../docs/adr/0047-psp-memory-budget.md)'s P1, captured from the
`psp-smoke` log rather than estimated. CI's `psp-smoke` job boots the EBOOT
under PPSSPP headless and checks that a marker appears, so a regression that
links but fails to boot is caught automatically. The job is **non-blocking**:
PPSSPP only partially implements
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

  Three prerequisite blockers the `psp` cross-build hit the moment it was
  actually exercised (found while scoping this slice, before any of it
  compiled against real pspdev headers — none of this was caught by CI, since
  the `psp` cross-build had never pulled `mruby-rgss` in before):
  - `mruby-rgss/src/terminal.cxx` (the sixel/iTerm2 backends) used POSIX
    `termios.h`/`sys/ioctl.h` and a `std::thread` writer unconditionally at
    file scope — unlike `psp.cxx`/`wio.cxx`, it was never self-guarded to be
    a no-op off its own target, so it would not have compiled against
    pspdev's newlib. Now guarded the same way (`#if !defined(PSP_BUILD) &&
    !defined(WIO_TERMINAL)`), with a stub for the one symbol
    (`rgss_terminal_poll`) called unconditionally elsewhere in the gem.
  - `mrbgem.rake` unconditionally linked `pthread`, needed only by that same
    `std::thread` writer. Now conditional on the *build's own* name (`psp`/
    `wio`), not on `MRUBY_TARGET` — that env var is also set while the
    native host build (which still needs pthread, to produce `mrbc`) runs
    in the same cross-compile session.
  - `mruby-mvjs` (RPG Maker MV/MZ via embedded QuickJS) links against `qjs`
    and optionally EGL/GLESv2, neither of which exists for MIPS/pspdev or is
    built by `app/psp`'s CMake project. MV/MZ was never in scope for this
    port, so `rpg_maker_gems(conf, include_mvjs: false)` drops it for `psp`
    specifically rather than porting QuickJS and a software GL stack as a
    side effect.

  Still ahead: building `uni-algo` for the `app/psp` CMake project (currently
  only LVGL is added as a subdirectory there; `mruby-rgss`/`mruby-lcf` both
  link it), actually invoking the `psp` mruby cross-build from
  `app/psp/CMakeLists.txt` and linking `libmruby.a` in (dropping the
  now-redundant direct `psp.cxx` compilation once the gem supplies it),
  deciding the `GAME_DIR` Memory-Stick path convention, and — per ADR
  0047's P2 — the mruby/LVGL allocator split.
- **Memory-Stick assets.** Game data is opened by path through mruby-io /
  `std::fopen`; on the PSP these resolve to newlib syscalls backed by the
  Memory Stick, which pspsdk's `stdio` already routes. Pointing `GAME_DIR` at a
  project on the stick follows once mruby is linked.
- **Accelerated rendering.** The bring-up flushes with a CPU `memcpy` into the
  framebuffer. Moving the blit onto the `sceGu` GPU is a later optimisation.

## Memory budget

The bring-up EBOOT never opens mruby, so it has never had to answer how the
game's live heap, LVGL's pool and decoded assets fit inside the PSP's ~24 MB
of RAM. [`docs/adr/0047-psp-memory-budget.md`](../../docs/adr/0047-psp-memory-budget.md)
works through that before the interpreter-linking slice lands, including a
real risk: mruby 4.0's global allocator hook defaults to sharing LVGL's pool
(as it does on desktop), so `lv_conf.h`'s 4 MB `LV_MEM_SIZE` may need to cover
the entire mruby object graph, not just LVGL widgets, unless a PSP-specific
allocator exception is added.

For a packed RPG Maker XP/VX/VX Ace title,
[`scripts/rgssad_unpack.rb`](../../scripts/rgssad_unpack.rb) unpacks
`Game.rgssad`/`.rgss2a`/`.rgss3a` into a loose file tree in place — the
loose-file-first loaders already prefer it over the archive, so this avoids
the whole-archive-resident-in-RAM read the packed form forces (see the ADR's
Finding 2). Excluding the packed archive from a given PSP deployment, so it
is never opened at all, is still a manual step the unpacker itself doesn't
take for you.
