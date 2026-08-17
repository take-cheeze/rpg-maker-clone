# PSP EBOOT

A pspdev/CMake target that runs the RPG Maker 2000/2003/XP/VX/VX Ace runtimes
on the Sony
[PlayStation Portable](https://en.wikipedia.org/wiki/PlayStation_Portable)
(Allegrex: MIPS32 R4000 @ 222/333 MHz, ~24 MB usable RAM, 480×272 LCD, D-pad +
analog stick + ✕○△□/L/R/Start/Select, Memory Stick).

This is additive to and independent of the desktop CMake build — building the
EBOOT does not touch the desktop/wasm builds, and vice versa. The design is in
[`docs/adr/0010-psp-port.md`](../../docs/adr/0010-psp-port.md).

## Status: HAL bring-up + the real RPG2k/XP/VX/VX Ace scene tree

This CMake project builds an EBOOT that opens an mruby interpreter and, if a
project is present at its fixed Memory Stick install location, detects which
maker it is for (RPG2k, RPG XP, or RPG VX / VX Ace) and constructs and drives
the real scene tree. It exists to prove the HAL, libmruby.a and now RGSS
itself compile, link and actually run a game on the console (and to get real
EBOOT size numbers from CI).

What runs today:

- `mruby-rgss/src/psp.cxx` — the HAL: an LVGL v9 display in **partial** render
  mode flushing to the 480×272 framebuffer via `sceDisplay` (accounting for the
  512-pixel line stride); the LVGL tick/delay source from the pspsdk system
  timer; and a scan of the D-pad, analog stick and ✕○△□ buttons into a bitmask.
  The display is created at whichever maker's project was detected (see
  below) at *its own* native resolution, not the panel's — the flush callback
  centers that logical canvas on the panel and clips every row to its actual
  480×272 bounds, so a canvas smaller than the panel (RPG2k's 320×240) is
  letterboxed and one larger than the panel in both dimensions (RPG XP's
  640×480, RPG VX/VX Ace's 544×416 — both designed for a desktop window, not
  a handheld LCD) shows only a same-scale, centered window onto the game's
  own screen; content outside that window still runs correctly but is not
  drawn. Built as part of `libmruby.a` (the `psp` mruby cross-build compiles
  the whole `mruby-rgss` gem, self-guarded on `PSP_BUILD`), not compiled into
  the EBOOT directly — `app/psp/CMakeLists.txt` links the archive in instead.
  `mruby-rgss/src/psp_input_bridge.cxx` polls the pad into `RGSS::Input`
  press/release events (`rgss_psp_poll`) once per frame from
  `Graphics.update`, so RGSS input needs no help from `main()`.
- `app/psp/main.cxx` — a pspsdk sketch (module metadata + HOME-exit callback)
  that probes `kGameDir` for a project (mirroring `src/main.cxx`'s
  `is_rpgvx_game`/`is_xp_game` maker-detection predicates and dispatch
  order), creates the display at that maker's native resolution (or the
  panel's own 480×272 if none matched, the idle bring-up path), draws a
  status screen that echoes the pressed keys while idle, and opens the
  interpreter (`mrb_open`, reported via the `RPG2K_PSP_MRUBY_OPEN` marker).
  RGSS is already registered the moment `mrb_open()` returns — `libmruby.a`'s
  gem_init runs every bundled gem's native `Init`, `RPG2k`/`RPGXP`/`RPGVX`
  included, the same as every other target (see `build_config.rb`'s
  `rpg_maker_gems`) — so nothing extra wires it in. `main.cxx` sets the
  `GAME_DIR`/`RTP_DIR` mruby constants the game gems' own mrblib read
  directly, and if a project was detected, constructs the matching class and
  drives its per-frame `#main_loop` once per C++ loop iteration instead of
  the desktop build's blocking `#start` — the same non-blocking shape the
  Emscripten build's `rpg_start_game` callback uses, since here too the
  *host* loop, not mruby, has to stay in charge of the process (heartbeat,
  HOME-button exit callback). `#main_loop` calls `Graphics.update` itself,
  which flushes LVGL and polls the pad, so `main()`'s own
  `lv_timer_handler()`/pad-scanning only run while idle (no project found, or
  construction failed). Construction and a clean-exit-vs-crash exit are
  reported via the `RPG2K_PSP_GAME_START` and `RPG2K_PSP_GAME_STOP` markers
  below. mruby still opens with its own default allocator (plain `malloc`),
  not routed through `lv_malloc` — ADR 0047's P2 remains open (see "Not yet
  wired").
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
[PPSSPP](https://www.ppsspp.org/), or copy it, together with an RPG Maker
2000/2003, XP, or VX/VX Ace project's files, to a Memory Stick at
`ms0:/PSP/GAME/rpg2k/EBOOT.PBP` on a homebrew-enabled console — that fixed
path is where `app/psp/main.cxx`'s `kGameDir` looks for a project. There is
no in-app project picker: one EBOOT install is one game.

The EBOOT writes five markers via `sceIoWrite` — `RPG2K_PSP_BOOT` once at
startup (a libc-free string literal); `RPG2K_PSP_MRUBY_OPEN ok` (or `FAILED`)
right after `mrb_open()`; `RPG2K_PSP_GAME_START <maker> ok`/`not_found`/
`FAILED` after attempting to construct the detected maker's class from
`kGameDir` (`<maker>` is `RPG2k`/`RPGXP`/`RPGVX`, or `none` when nothing
matched); `RPG2K_PSP_GAME_STOP exit`/`error` if a running game later raises
(a clean `Kernel#exit` vs. an actual crash); and `RPG2K_PSP_BRINGUP
frame=N free=N maxfree=N lvgl_used=N lvgl_max=N stack_free=N
stack_used_max=N` once a second. `free`/`maxfree` are
`sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize` (the device's actual
free RAM); `lvgl_used`/`lvgl_max` are `lv_mem_monitor`'s current/high-water-mark
use of LVGL's own pool; `stack_free`/`stack_used_max` are
`sceKernelGetThreadStackFreeSize`'s scan of the still-untouched (0xFF-filled)
low end of the main thread's 256 KB stack and the deepest use seen so far —
since a down-growing stack never restores those bytes, even a single sample is
already a high-water mark (P5). All of them are real numbers for
[ADR 0047](../../docs/adr/0047-psp-memory-budget.md)'s P1, captured from the
`psp-smoke` log rather than estimated, and now against a real game's usage
once one is deployed to `kGameDir` instead of just the idle HAL's. CI's
`psp-smoke` job boots the EBOOT under PPSSPP headless and checks that a
marker appears, so a regression that links but fails to boot is caught
automatically; it has no project at `kGameDir`, so it only ever exercises the
idle path (`RPG2K_PSP_GAME_START none not_found`). The job is
**non-blocking**:
PPSSPP only partially implements
pspsdk's libc stdio (plain `printf` is an unimplemented HLE import there), so
emulator capture can be fragile — the required build gate is the `psp` job. To
reproduce locally, run PPSSPP's headless binary with `--log` (needed to surface
the `sceIoWrite` output). CI takes that binary from nixpkgs instead of building
it, and the same package works locally — `nix build '.#ppsspp'` puts it at
`./result/bin/ppsspp-headless` (it finds its own assets, so the working
directory does not matter):

```sh
nix build '.#ppsspp'
./result/bin/ppsspp-headless --log --graphics=software --timeout=15 EBOOT.PBP
```

## Not yet wired (later slices)

The pieces below are scaffolded but **not** part of the EBOOT yet:

- **Full-canvas scaling for RPG XP / VX / VX Ace.** Their native resolutions
  (640×480, 544×416) are both larger than the 480×272 panel in *both*
  dimensions — they were designed for a resizable desktop window, not a
  fixed handheld LCD. `psp.cxx`'s flush callback currently centers a
  same-scale window onto the game's own canvas rather than resampling it
  down to fit, so content near an edge of the game's screen is never drawn.
  Real per-pixel resampling (or GPU-accelerated scaling once `sceGu` lands,
  see below) would show the whole screen at once, at the cost of real
  per-frame CPU work this bring-up has not attempted or profiled.
- **A configurable `GAME_DIR`.** The Memory Stick path is a fixed constant
  (`ms0:/PSP/GAME/rpg2k`), matching one-EBOOT-one-game — there is no
  equivalent of the desktop build's `--game_dir` flag or the browser build's
  runtime project loader, since the PSP EBOOT has no command line and no
  way to be told a different location after it starts.
- **Validating ADR 0047's P2 numbers.** The mruby/LVGL allocator split itself
  is decided and wired (mruby's whole heap lives in its own 8 MB arena, see
  `main.cxx`'s `mrb_basic_alloc_func` — LVGL's pool only aligns to 4 bytes on
  32-bit, too weak for mruby's word boxing, so sharing it is not an option
  the way it is on desktop). What still needs a real game running at
  `kGameDir` is confirming the arena size is right: the `RPG2K_PSP_BRINGUP`
  heartbeat reports free RAM and LVGL's pool high-water mark, and the
  mruby arena's own usage is the gap between `sceKernelTotalFreeMemSize` and
  those two, once a title actually runs on hardware or an emulator.
- **Accelerated rendering.** The bring-up flushes with a CPU `memcpy` into the
  framebuffer. Moving the blit onto the `sceGu` GPU is a later optimisation,
  and the natural place to also do real scaling (above) instead of clipping.

## Memory budget

CI has no project at `kGameDir`, so it only ever exercises the idle HAL —
answering how the game's live heap, LVGL's pool and decoded assets actually
fit inside the PSP's ~24 MB of RAM still needs a real game run on real
hardware or an emulator with a Memory Stick image, not just CI's `psp-smoke`.
[`docs/adr/0047-psp-memory-budget.md`](../../docs/adr/0047-psp-memory-budget.md)
works through that, including the P2 allocator split, which is now decided and
wired: mruby's entire heap lives in a fixed 8 MB arena of its own
(`main.cxx`'s `mrb_basic_alloc_func`) rather than sharing LVGL's pool (whose
TLSF only 4-byte-aligns on 32-bit — too weak for mruby's word boxing) or
growing unbounded on plain malloc, so the interpreter OOMs into a catchable
`NoMemoryError` instead of colliding with the decoded-bitmap heap. `lv_conf.h`'s
4 MB `LV_MEM_SIZE` therefore covers only LVGL's own widgets and internals, and
the decoded bitmaps stay in a third, uncapped pool as before.

Beyond the arena, this port also shrinks the live footprint in four smaller
ways: the LVGL partial-render buffers are sized to the game's own canvas
(RPG2k's 320×240 fits ~38 KB per buffer instead of the fixed panel-width 64 KB
each — see `psp.cxx`), the EBOOT links none of LVGL's examples/demos and only
the widgets the RGSS layer actually uses (canvas/image/label; the default theme
that pulled every widget into the link is off), the mruby cross-build runs
the embedded tuning knobs (`MRB_HEAP_PAGE_SIZE`/`KHASH_INITIAL_SIZE` — see
`build_config.rb`), and the uni-algo Unicode tables are cut to the modules this
project calls (`cmake/uni-algo-trim.cmake`), which alone is ~506 KB — on the
PSP every PT_LOAD segment of the EBOOT is mapped into RAM at launch, so a
read-only table is live memory, not just file size. The
`RPG2K_PSP_BRINGUP` heartbeat is the place to read the
result: `free`/`maxfree` from `sceKernelTotalFreeMemSize` are the device's real
free RAM, `lvgl_used`/`lvgl_max` are LVGL's pool, and the mruby arena's usage is
the gap between them once a game is actually running.

For a packed RPG Maker XP/VX/VX Ace title,
[`scripts/rgssad_unpack.rb`](../../scripts/rgssad_unpack.rb) unpacks
`Game.rgssad`/`.rgss2a`/`.rgss3a` into a loose file tree in place — the
loose-file-first loaders already prefer it over the archive, so this avoids
the whole-archive-resident-in-RAM read the packed form forces (see the ADR's
Finding 2). Excluding the packed archive from a given PSP deployment, so it
is never opened at all, is still a manual step the unpacker itself doesn't
take for you.
