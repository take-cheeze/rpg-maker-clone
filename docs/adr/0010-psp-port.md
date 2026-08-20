# 10. Porting the RPG2k runtime to the Sony PSP (Allegrex)

Date: 2026-08-03

## Status

Proposed

## Context

A core project goal (see ADR 1) is to run RPG Maker games "on any environment
such like embedded boards." After the Wio Terminal (ADR 7), the Sony
**PlayStation Portable** is a natural second real hardware target: it is a
self-contained handheld with a screen, buttons and removable storage, and it is
comfortably larger than the Wio Terminal:

- Allegrex CPU (MIPS32 R4000 + VFPU) @ 222/333 MHz
- **~24 MB usable user RAM** (32 MB physical) and 2 MB VRAM
- 480×272 LCD (RGB565/8888), scanned with a 512-pixel line stride
- D-pad, analog stick, ✕○△□, L/R, Start/Select
- Memory Stick storage; a mature open toolchain (**pspdev / pspsdk**)

The runtime is already structured so a new display target is additive rather
than a rewrite — the same property that made the sixel (ADR 1), iTerm2 (ADR 3),
Emscripten and Wio (ADR 7) backends cheap:

- **Rendering is LVGL, and LVGL is display-agnostic.** A display is a draw
  buffer plus a flush callback; the game never talks to SDL directly. The active
  display is injected once through the `rgss_set_display(M, d)` seam
  (`src/main.cxx`) and read back via `get_display` (`mruby-rgss/src/lib.cxx`).
- **Input arrives through per-frame poll hooks.** `gfx_update`
  (`mruby-rgss/src/lib.cxx`) already calls `rgss_terminal_poll`, `rgss_sdl_poll`
  and `rgss_wio_poll` side by side; adding a backend means adding one more poll
  hook of the same shape, buffering key transitions and draining them into
  `RGSS::Input` with the integer key ids shared across backends.
- **Non-SDL timing is a solved problem.** The terminal and Wio backends install
  LVGL's tick/delay via `lv_tick_set_cb`/`lv_delay_set_cb` instead of relying on
  SDL; the PSP does the same from its system timer.
- **Handing the frame loop to a host is a solved problem.** The Emscripten and
  Wio builds run one `main_loop` iteration per host tick rather than the blocking
  Ruby `loop`; `main()` on the PSP owns the loop the same way.

Unlike the Wio Terminal, the PSP has ample RAM, so the memory-budget pressure
that dominates ADR 7 (192 KB SRAM) is not the constraining force here — the open
question is instead getting the toolchain, LVGL and (later) the full mruby gem
set to cross-compile for MIPS and package into an `EBOOT.PBP`.

## Decision

Add a PSP backend mirroring the Wio port's structure, and land it as a
**bring-up slice** first (display + input, no interpreter), so the HAL is proven
and CI-checked before the interpreter and assets are layered on:

- **HAL** in the `mruby-rgss` gem, self-guarded on `PSP_BUILD` so the
  desktop/wasm globs see an empty file:
  - `mruby-rgss/src/psp.cxx` (+ `include/psp.hxx`) — an LVGL v9 display in
    partial render mode flushing to the `sceDisplay` framebuffer (RGB565, with
    the 512-pixel stride handled in the flush), the tick/delay source from
    `sceKernelGetSystemTimeLow`/`sceKernelDelayThread`, and a `sceCtrl` scan of
    the D-pad, analog stick and ✕○△□ into a bitmask. Cross/Circle/Triangle map to
    C/B/A to match the desktop Z/X/C = confirm/cancel/A convention.
  - `mruby-rgss/src/psp_input_bridge.cxx` — the mruby half (`rgss_psp_poll`),
    wired into `gfx_update` next to the other backends, translating the bitmask
    into `RGSS::Input` press/release edges.
- **EBOOT** under `app/psp/`: a standalone pspdev CMake project (`CMakeLists.txt`
  + `main.cxx` + a PSP-tuned `lv_conf.h`) that builds `EBOOT.PBP` via
  `create_pbp_file`, independent of the root CMake build — the same "separate and
  additive" split platformio.ini uses for the Wio firmware.
- **mruby cross target**: a `MRuby::CrossBuild.new('psp')` in `build_config.rb`
  (`MRUBY_TARGET=psp`, `psp-gcc`/`psp-g++`, `-G0`, `PSP_BUILD`) that produces the
  `libmruby.a` a later slice links into the EBOOT. Gated on `MRUBY_TARGET`, so it
  never affects the desktop or wasm builds.
- **CI**: a `psp` job building the bring-up EBOOT with the `pspdev/pspdev`
  container. This environment cannot cross-build or flash a PSP, so — exactly as
  for the Wio job — CI is the external check that the HAL and EBOOT compile. A
  second `psp-smoke` job goes further than the Wio port did: it boots the EBOOT
  under **PPSSPP** headless (software renderer) and checks for the bring-up
  markers it writes via `sceIoWrite` — a libc-free `RPG2K_PSP_BOOT` literal
  emitted before any init, plus the per-second `RPG2K_PSP_BRINGUP` heartbeat — so
  CI verifies the EBOOT actually runs on an emulator, not just that it links.
  PPSSPP comes from nixpkgs (`packages.ppsspp` in `flake.nix`, whose default
  non-Qt build configures `-DHEADLESS=ON` and installs `bin/ppsspp-headless`),
  pinned by `flake.lock` and substituted prebuilt from `cache.nixos.org` rather
  than compiled in CI. The job was **non-blocking** (`continue-on-error`):
  PPSSPP only partially HLE-implements pspsdk's libc stdio (plain
  `printf`/`strlen` resolve to firmware stubs), so the markers deliberately
  avoid libc where possible, but emulator capture could still be fragile; the
  required gate was the `psp` build.
  **Update:** `flake.nix`'s `packages.ppsspp` now carries local patches (see
  `nix/patches/`) fixing several PPSSPP HLE/interpreter bugs found chasing the
  EBOOT's own boot-to-completion goal, so it changes the derivation's output
  hash and every `nix build '.#ppsspp'` compiles PPSSPP from source instead of
  substituting `cache.nixos.org`'s prebuilt closure. With those fixes, the
  EBOOT boots to completion and `psp-smoke` captures its markers reliably
  (see `docs/adr/0047-psp-memory-budget.md`'s addendum); `continue-on-error`
  has been removed, and `psp-smoke` is now a required check alongside `psp`.

## Consequences

- The PSP HAL follows the exact seam the Wio port validated, so a reviewer can
  read the two side by side; the shared LVGL/`RGSS::Input`/tick abstractions mean
  no engine changes beyond one guarded poll hook in `gfx_update`.
- CI now compiles the EBOOT on every push (the `psp` job) and boots it under
  PPSSPP headless (the `psp-smoke` job), catching both build bit-rot and a boot
  that links but crashes or never renders. Richer on-device verification
  (real hardware, or PPSSPP's GUI to eyeball the screen and the red/blue channel
  order) is still manual.
- The bring-up EBOOT links neither `libmruby` nor the input bridge, so the
  `psp` mruby cross target and `psp_input_bridge.cxx` are checked in but unused
  until the next slice wires the interpreter and starts the real `RPG2k` scene
  tree. Memory-Stick asset loading (newlib syscalls, already routed by pspsdk's
  stdio) and moving the framebuffer blit onto `sceGu` follow after that.
  **Update:** that next slice has landed, and now covers XP/VX/VX Ace too.
  `libmruby.a` links into the EBOOT and opens (`RPG2K_PSP_MRUBY_OPEN`), and
  `app/psp/main.cxx` detects which maker's project (if any) is present at a
  fixed Memory Stick install location (`ms0:/PSP/GAME/rpg2k`), constructs
  the matching class (`RPG2k`/`RPGXP`/`RPGVX`) at its own native display
  resolution, and drives its per-frame `#main_loop`, reporting the outcome
  via `RPG2K_PSP_GAME_START`/`RPG2K_PSP_GAME_STOP`. RPG XP and RPG VX/VX
  Ace's native resolutions both exceed the 480×272 panel in both dimensions
  (they were designed for a desktop window), so `psp.cxx`'s flush callback
  centers and clips rather than scales — see `app/psp/README.md` for the
  current status and what's still ahead (full-canvas scaling, the allocator
  split, `sceGu`).
- Because the PSP has ~24 MB of RAM, the gem-trimming and streaming-asset work
  that ADR 7 needs for the Wio Terminal is not expected to be necessary here; the
  full gem set should fit.
  This claim is about gem *code* size only — it does not cover per-title asset
  memory once the interpreter is linked. See ADR 0047 for the memory-budget
  analysis (and its risks) that the interpreter-linking slice should settle
  before `LV_MEM_SIZE` and the mruby allocator split are picked for real.
