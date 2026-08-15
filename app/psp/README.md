# PSP EBOOT

A pspdev/CMake target that runs the RPG2k runtime on the Sony
[PlayStation Portable](https://en.wikipedia.org/wiki/PlayStation_Portable)
(Allegrex: MIPS32 R4000 @ 222/333 MHz, ~24 MB usable RAM, 480×272 LCD, D-pad +
analog stick + ✕○△□/L/R/Start/Select, Memory Stick).

This is additive to and independent of the desktop CMake build — building the
EBOOT does not touch the desktop/wasm builds, and vice versa. The design is in
[`docs/adr/0010-psp-port.md`](../../docs/adr/0010-psp-port.md).

## Status: HAL bring-up + interpreter boot

This CMake project builds a **hardware bring-up EBOOT**: it stands up the LVGL
display over the LCD, reads the pad, and opens an mruby interpreter — without
starting a game. It exists to prove the HAL and libmruby.a compile, link and
run on the console (and to get real EBOOT size numbers from CI).

What runs today:

- `mruby-rgss/src/psp.cxx` — the HAL: an LVGL v9 display in **partial** render
  mode flushing to the 480×272 framebuffer via `sceDisplay` (accounting for the
  512-pixel line stride); the LVGL tick/delay source from the pspsdk system
  timer; and a scan of the D-pad, analog stick and ✕○△□ buttons into a bitmask.
  Built as part of `libmruby.a` (the `psp` mruby cross-build compiles the whole
  `mruby-rgss` gem, self-guarded on `PSP_BUILD`), not compiled into the EBOOT
  directly — `app/psp/CMakeLists.txt` links the archive in instead.
- `app/psp/main.cxx` — a pspsdk sketch (module metadata + HOME-exit callback)
  that draws a status screen, echoes the pressed keys, and opens the
  interpreter (`mrb_open`, reported via the `RPG2K_PSP_MRUBY_OPEN` marker
  below). `main()` owns the loop and pumps LVGL once per iteration, mirroring
  the Emscripten and Wio builds. Its heartbeat also reports free device RAM
  and LVGL pool usage (see below). No RGSS methods are registered and no game
  is started yet — the interpreter opens with mruby's own default allocator
  (plain `malloc`) and then just sits there.
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

The bring-up writes three markers via `sceIoWrite` — `RPG2K_PSP_BOOT` once at
startup (a libc-free string literal), `RPG2K_PSP_MRUBY_OPEN ok` (or `FAILED`)
right after `mrb_open()`, and `RPG2K_PSP_BRINGUP
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

- **The real `RPG2k` scene tree.** `mruby-rgss/src/psp_input_bridge.cxx`
  already translates the pad bitmask into `RGSS::Input` press/release events
  (`rgss_psp_poll`, called from `Graphics.update`), and `libmruby.a` (the
  `psp` mruby cross-build, `MRUBY_TARGET=psp`) is now linked into the EBOOT
  and opens successfully (`RPG2K_PSP_MRUBY_OPEN ok`). What's not wired yet:
  registering the RGSS native methods and actually instantiating `RPG2k.new`
  against a real game directory — `app/psp/main.cxx` opens the interpreter
  and stops there.
- **Memory-Stick assets / `GAME_DIR`.** Game data is opened by path through
  mruby-io / `std::fopen`; on the PSP these resolve to newlib syscalls backed
  by the Memory Stick, which pspsdk's `stdio` already routes. What's missing
  is deciding and setting the `GAME_DIR` Memory-Stick path convention itself
  (e.g. relative to the EBOOT's own directory) — needed before `RPG2k.new`
  can find anything.
- **ADR 0047's P2 (the mruby/LVGL allocator split).** `main.cxx` currently
  opens mruby with its own default allocator (plain `malloc`), not routed
  through `lv_malloc` the way the desktop build's `mrb_basic_alloc_func`
  override does. Proving the interpreter boots didn't require deciding this;
  starting a real game — where the pool size actually matters — does.
- **Accelerated rendering.** The bring-up flushes with a CPU `memcpy` into the
  framebuffer. Moving the blit onto the `sceGu` GPU is a later optimisation.

## Memory budget

The bring-up EBOOT opens mruby but starts no game, so it has not yet had to
answer how the game's live heap, LVGL's pool and decoded assets fit inside
the PSP's ~24 MB of RAM.
[`docs/adr/0047-psp-memory-budget.md`](../../docs/adr/0047-psp-memory-budget.md)
works through that before a real game is started, including a real risk:
mruby 4.0's global allocator hook defaults to sharing LVGL's pool (as it does
on desktop) if `main.cxx` ever installs that override the way the desktop
build's `mrb_basic_alloc_func` does — which it does not yet (see "Not yet
wired" above) — so `lv_conf.h`'s 4 MB `LV_MEM_SIZE` may need to cover the
entire mruby object graph, not just LVGL widgets, unless a PSP-specific
allocator exception is added instead.

For a packed RPG Maker XP/VX/VX Ace title,
[`scripts/rgssad_unpack.rb`](../../scripts/rgssad_unpack.rb) unpacks
`Game.rgssad`/`.rgss2a`/`.rgss3a` into a loose file tree in place — the
loose-file-first loaders already prefer it over the archive, so this avoids
the whole-archive-resident-in-RAM read the packed form forces (see the ADR's
Finding 2). Excluding the packed archive from a given PSP deployment, so it
is never opened at all, is still a manual step the unpacker itself doesn't
take for you.
