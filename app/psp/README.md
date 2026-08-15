# PSP EBOOT

A pspdev/CMake target that runs the RPG2k runtime on the Sony
[PlayStation Portable](https://en.wikipedia.org/wiki/PlayStation_Portable)
(Allegrex: MIPS32 R4000 @ 222/333 MHz, ~24 MB usable RAM, 480×272 LCD, D-pad +
analog stick + ✕○△□/L/R/Start/Select, Memory Stick).

This is additive to and independent of the desktop CMake build — building the
EBOOT does not touch the desktop/wasm builds, and vice versa. The design is in
[`docs/adr/0010-psp-port.md`](../../docs/adr/0010-psp-port.md).

## Status: HAL bring-up + the real RPG2k scene tree

This CMake project builds an EBOOT that opens an mruby interpreter and, if a
project is present at its fixed Memory Stick install location, constructs and
drives the real `RPG2k` scene tree. It exists to prove the HAL, libmruby.a and
now RGSS itself compile, link and actually run a game on the console (and to
get real EBOOT size numbers from CI).

What runs today:

- `mruby-rgss/src/psp.cxx` — the HAL: an LVGL v9 display in **partial** render
  mode flushing to the 480×272 framebuffer via `sceDisplay` (accounting for the
  512-pixel line stride); the LVGL tick/delay source from the pspsdk system
  timer; and a scan of the D-pad, analog stick and ✕○△□ buttons into a bitmask.
  Built as part of `libmruby.a` (the `psp` mruby cross-build compiles the whole
  `mruby-rgss` gem, self-guarded on `PSP_BUILD`), not compiled into the EBOOT
  directly — `app/psp/CMakeLists.txt` links the archive in instead.
  `mruby-rgss/src/psp_input_bridge.cxx` polls the pad into `RGSS::Input`
  press/release events (`rgss_psp_poll`) once per frame from
  `Graphics.update`, so RGSS input needs no help from `main()`.
- `app/psp/main.cxx` — a pspsdk sketch (module metadata + HOME-exit callback)
  that draws a status screen, echoes the pressed keys while idle, and opens
  the interpreter (`mrb_open`, reported via the `RPG2K_PSP_MRUBY_OPEN`
  marker). RGSS is already registered the moment `mrb_open()` returns —
  `libmruby.a`'s gem_init runs every bundled gem's native `Init`, RPG2k
  included, the same as every other target (see `build_config.rb`'s
  `rpg_maker_gems`) — so nothing extra wires it in. `main.cxx` sets the
  `GAME_DIR`/`RTP_DIR` mruby constants mruby-rpg2k/mruby-rgss read directly,
  and if `RPG_RT.ldb` exists there, constructs `RPG2k.new` and drives its
  per-frame `#main_loop` once per C++ loop iteration instead of the desktop
  build's blocking `#start` — the same non-blocking shape the Emscripten
  build's `rpg_start_game` callback uses, since here too the *host* loop, not
  mruby, has to stay in charge of the process (heartbeat, HOME-button exit
  callback). `#main_loop` calls `Graphics.update` itself, which flushes LVGL
  and polls the pad, so `main()`'s own `lv_timer_handler()`/pad-scanning only
  run while idle (no project found, or construction failed). Construction and
  a clean-exit-vs-crash exit are reported via the `RPG2K_PSP_GAME_START` and
  `RPG2K_PSP_GAME_STOP` markers below. mruby still opens with its own default
  allocator (plain `malloc`), not routed through `lv_malloc` — ADR 0047's P2
  remains open (see "Not yet wired").
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
2000/2003 project's files, to a Memory Stick at
`ms0:/PSP/GAME/rpg2k/EBOOT.PBP` on a homebrew-enabled console — that fixed
path is where `app/psp/main.cxx`'s `kGameDir` looks for `RPG_RT.ldb`. There is
no in-app project picker: one EBOOT install is one game. RPG Maker XP/VX/VX
Ace projects aren't detected yet (see "Not yet wired").

The EBOOT writes five markers via `sceIoWrite` — `RPG2K_PSP_BOOT` once at
startup (a libc-free string literal); `RPG2K_PSP_MRUBY_OPEN ok` (or `FAILED`)
right after `mrb_open()`; `RPG2K_PSP_GAME_START ok`/`not_found`/`FAILED`
after attempting to construct `RPG2k` from `kGameDir`; `RPG2K_PSP_GAME_STOP
exit`/`error` if a running game later raises (a clean `Kernel#exit` vs. an
actual crash); and `RPG2K_PSP_BRINGUP
frame=N free=N maxfree=N lvgl_used=N lvgl_max=N` once a second, the last four
fields being `sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize` (the
device's actual free RAM) and `lv_mem_monitor`'s current/high-water-mark use
of LVGL's own pool — real numbers for
[ADR 0047](../../docs/adr/0047-psp-memory-budget.md)'s P1, captured from the
`psp-smoke` log rather than estimated, and now against a real game's usage
once one is deployed to `kGameDir` instead of just the idle HAL's. CI's
`psp-smoke` job boots the EBOOT under PPSSPP headless and checks that a
marker appears, so a regression that links but fails to boot is caught
automatically; it has no project at `kGameDir`, so it only ever exercises the
idle path (`RPG2K_PSP_GAME_START not_found`). The job is **non-blocking**:
PPSSPP only partially implements
pspsdk's libc stdio (plain `printf` is an unimplemented HLE import there), so
emulator capture can be fragile — the required build gate is the `psp` job. To
reproduce locally, run PPSSPP's headless binary with `--log` (needed to surface
the `sceIoWrite` output):

```sh
PPSSPPHeadless --log --graphics=software --timeout=15 EBOOT.PBP
```

## Not yet wired (later slices)

The pieces below are scaffolded but **not** part of the EBOOT yet:

- **RPG Maker XP / VX / VX Ace detection.** `kGameDir` in `app/psp/main.cxx`
  only ever checks for `RPG_RT.ldb` (RPG2k) — ADR 0010 scopes the PSP port to
  "starting the real RPG2k scene tree". The desktop/Emscripten maker-detection
  chain (`is_rpgvx_game`/`is_xp_game` in `src/main.cxx`) is the pattern to
  follow once this path is proven; `RPGXP`/`RPGVX` are already linked into
  `libmruby.a` the same way `RPG2k` is (`rpg_maker_gems`), just never
  constructed here.
- **A configurable `GAME_DIR`.** The Memory Stick path is a fixed constant
  (`ms0:/PSP/GAME/rpg2k`), matching one-EBOOT-one-game — there is no
  equivalent of the desktop build's `--game_dir` flag or the browser build's
  runtime project loader, since the PSP EBOOT has no command line and no
  way to be told a different location after it starts.
- **ADR 0047's P2 (the mruby/LVGL allocator split).** `main.cxx` still opens
  mruby with its own default allocator (plain `malloc`), not routed through
  `lv_malloc` the way the desktop build's `mrb_basic_alloc_func` override
  does. Starting a real game didn't require deciding this either; it needs
  real on-device numbers from an actual game running at `kGameDir` first (see
  "Memory budget" below).
- **Accelerated rendering.** The bring-up flushes with a CPU `memcpy` into the
  framebuffer. Moving the blit onto the `sceGu` GPU is a later optimisation.

## Memory budget

CI has no project at `kGameDir`, so it only ever exercises the idle HAL —
answering how the game's live heap, LVGL's pool and decoded assets actually
fit inside the PSP's ~24 MB of RAM still needs a real game run on real
hardware or an emulator with a Memory Stick image, not just CI's `psp-smoke`.
[`docs/adr/0047-psp-memory-budget.md`](../../docs/adr/0047-psp-memory-budget.md)
works through that, including a real risk: mruby 4.0's global allocator hook
defaults to sharing LVGL's pool (as it does on desktop) if `main.cxx` ever
installs that override the way the desktop build's `mrb_basic_alloc_func`
does — which it does not yet (see "Not yet wired" above) — so `lv_conf.h`'s
4 MB `LV_MEM_SIZE` may need to cover the entire mruby object graph, not just
LVGL widgets, unless a PSP-specific allocator exception is added instead.

For a packed RPG Maker XP/VX/VX Ace title,
[`scripts/rgssad_unpack.rb`](../../scripts/rgssad_unpack.rb) unpacks
`Game.rgssad`/`.rgss2a`/`.rgss3a` into a loose file tree in place — the
loose-file-first loaders already prefer it over the archive, so this avoids
the whole-archive-resident-in-RAM read the packed form forces (see the ADR's
Finding 2). Excluding the packed archive from a given PSP deployment, so it
is never opened at all, is still a manual step the unpacker itself doesn't
take for you.
