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
set (it provides `psp-gcc`, the CMake toolchain file and `create_pbp_file`).
Run `scripts/build_psp_fixup_imports.bash` first — it replaces the
toolchain's own `psp-fixup-imports` (normally at `$PSPDEV/bin/`) with a
patched build; see the bug trail lower in this section for why this
EBOOT needs it to actually boot:

```sh
scripts/build_psp_fixup_imports.bash "$PSPDEV/bin/psp-fixup-imports"
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
idle path (`RPG2K_PSP_GAME_START none not_found`). The job is currently
**non-blocking** (the required build gate is the `psp` job) — a holdover
from when the EBOOT did not boot to completion under PPSSPP-headless; now
that it does (see below), promoting `psp-smoke` to a required check is
worth revisiting. Nine independent bugs were found and root-caused
chasing that boot-to-completion goal; eight of them fixed, the remaining
one (pspsdk's own upstream bug) no longer reachable — **boot now
completes**:

- pspsdk's `sysclib_snprintf`/`sysclib_sprintf` HLE stubs are only partially
  implemented under PPSSPP-headless, and calling into them left the
  emulator's own state corrupted badly enough to contribute to crashes
  reachable from this EBOOT's own code — `main.cxx` now builds every
  marker/status string with a small libc-free `StrBuf` instead (append-only,
  integers formatted by hand), the same reasoning the `RPG2K_PSP_BOOT`
  marker's string-literal already used.
- PPSSPP-headless's own kernel-object emulation had a real upstream bug,
  confirmed by running it locally under `gdb` on the resulting core dump:
  `sceKernelCreateLwMutex` (`Core/HLE/sceKernelMutex.cpp`) dereferenced its
  caller-supplied workarea pointer without validating it first, unlike every
  sibling `LwMutex` function in the same file — a guest passing
  `workareaPtr=0` turned that into a null-pointer write that segfaulted the
  *host* `ppsspp-headless` process rather than raising a guest-catchable
  error. Not yet upstreamed to `hrydgard/ppsspp`;
  `nix/patches/ppsspp-lwmutex-workarea-validate.patch` applies it locally.
- Separately, PPSSPP's interpreter treated the Allegrex `mfic`/`mtic`
  instructions ("move from/to interrupt controller") as no-ops. pspsdk's own
  `pspSdkDisableInterrupts()`/`EnableInterrupts()` are built directly on
  those two instructions to guard its non-reentrant C-runtime state without
  syscall overhead; as no-ops, they gave no real protection, letting a
  timer/thread interrupt land mid-"critical section". Also not yet
  upstreamed; `nix/patches/ppsspp-mfic-mtic-interrupt-mask.patch` applies it
  locally, alongside the LwMutex one.
- `app/psp/CMakeLists.txt` used to link `pspkernel` before `pspuser`. Both
  provide `sceKernelCreateCallback`/`sceKernelSleepThreadCB`/
  `sceKernelMaxFreeMemSize` as distinct `ForKernel`/`ForUser` NIDs, and with
  `pspkernel` first the linker kept its (wrong, for a user-mode EBOOT)
  `ForKernel` stub for all three — every call silently returned an error
  none of the callers checked, which is what was actually hanging boot past
  `RPG2K_PSP_BOOT` (`_sbrk`'s heap-init probe re-ran forever). Linking
  `pspuser` first fixed it.

A third bug — a real one, in pspsdk's own `__retarget_lock_init_recursive`
(missing a null-check after `malloc()`) — is confirmed present but no
longer reachable on this boot path: it only ever triggered because of the
`_sbrk`/`sceKernelMaxFreeMemSize` bug just above, and with that fixed,
`malloc()` for the affected lock struct no longer fails. Worth reporting
upstream, not worth working around here.

- A fourth bug, also fixed: `psp-fixup-imports` (pspsdk's post-link import
  tool) requires every call site referencing a given PSP module to be
  physically contiguous in the linked binary, and traced to its source (not
  just the "stubs out of order" symptom it prints) this turns out to
  reflect genuinely necessary separation in `main.cxx`'s own control flow —
  e.g. `setup_callbacks()`'s one-time `ThreadManForUser` calls versus the
  ongoing per-second heartbeat's own, much later call into the same module
  — not an accidental ordering slip a source reorder could fix. A patch
  that just regroups the tool's metadata by module was tried first and
  found unsafe (it silently misdirects syscalls — confirmed: it produced a
  binary where `sceKernelCreateThread` and `sceIoRemove` resolved to the
  same trampoline address); the real fix additionally scans every
  executable section for `jal` instructions targeting a moved slot and
  repoints them, the same relocation work a real ET_EXEC loader would do
  and this prebuilt-binary tool skips.
  `scripts/build_psp_fixup_imports.bash` fetches pspsdk at the pinned
  commit `patches/psp-fixup-imports-jal-relocation-aware.patch` targets,
  applies it, and drops the rebuilt tool in place of the container's own —
  wired into the `psp` CI job ahead of `psp-cmake`/`cmake --build`. Not yet
  upstreamed to `pspdev/pspsdk`.

With that fixed, this EBOOT boots dramatically further than at any earlier
point on this whole trail — past `RPG2K_PSP_BOOT`, through `_sbrk`'s heap
init, through `mrb_open`, into real LVGL widget creation — and hit a
**seventh bug, also fixed**: LVGL's builtin TLSF allocator asserted `block
already marked as free` inside `lv_tlsf_realloc`. Confirmed not a sizing
issue (bumping `LV_MEM_SIZE` 8x made no difference); root-caused with a
print-capable `LV_ASSERT_HANDLER` to `psp_display_create`
(`mruby-rgss/src/psp.cxx`), where `std::vector<uint8_t>::assign(n, 0)` —
used to size and zero the two LVGL draw buffers — is broken on this pspdev
g++/libstdc++ build specifically when growing an empty vector: it
allocates correctly but leaves the vector's `data()` null (`resize(n)`
does not share the bug). The resulting null/wild buffer, fed into
`lv_display_set_buffers`, is what corrupted LVGL's own TLSF pool further
down the boot path. With that fixed, the EBOOT boots past display
creation and into `mrb_open`'s GC init before hitting an **eighth bug,
fixed**: PPSSPP reported `Bad memory access detected! 00000014` (or a
nearby address) and separately spammed `Unknown syscall ... (module: 255
func: 4095)` dozens of times during boot. Three earlier passes
misdiagnosed this (as a PPSSPP JIT bug, then a timing race, then a
boxed-`mrb_value`/`const char*` type confusion inside mruby); a fourth
pass, instrumenting `psp-fixup-imports` itself to print its own grouping
decisions, found the real cause: the grouping is fully correct (the
earlier `psp-nm`/`psp-objdump` cross-references were reading *stale*
symbol addresses, from before the tool's own intentional reorder), and
the actual function at the faulting slot was `strtoul`
(`SysclibForKernel`, NID `0x6A7900E1`) — one of four `SysclibForKernel`
imports (`strtoul`, `strncat` `0xD3D1A3B9`, `memchr` `0x68A78817`,
`tolower` `0x3EC5BBF6`) that PPSSPP's own loader correctly recognizes by
NID but has no HLE handler for, out of the sixteen this EBOOT pulls in
(the other twelve, e.g. `strlen`/`memcpy`/`memset`, PPSSPP does
implement). Every call to one of the four missing functions silently
did nothing and returned whatever garbage was already in the return
register — that is what produced this whole bug's symptoms (the
near-null reads, which happen to match `mruby/boxing_word.h`'s special
constants coincidentally rather than from any real type confusion, and
the eventual fatal `strlen` call on garbage). Fixed by adding all four
to PPSSPP's `SysclibForKernel` HLE table, matching its existing
entries' style — `nix/patches/ppsspp-sysclibforkernel-missing-functions.patch`.
Verified: rebuilding PPSSPP with this patch drops the `Unknown syscall`
count from ~90 to 1 and eliminates the `Bad memory access` flood
entirely.

With bug 8 fixed, the EBOOT reached a **ninth bug — fixed, the last
blocker on this whole trail**: `3rd/mruby/src/gc.c`'s
`mrb_assert(is_gray(obj))` inside `gc_mark_children` fired for real —
the first genuine mruby-internal assertion message this whole trail
reached (`assertion "((obj)->gc_color == 0)" failed`, captured via
`sceIoWrite` the same way every other marker here is). Several deep
trace passes ruled out a null `mrb_heap_page`, `MRB_HEAP_PAGE_SIZE=256`
(tested against the desktop/wasm-matching default 1024 — reproduced
identically either way), and the fixed arena allocator itself
(confirmed completely healthy across the whole crash window with
unconditional tracing) before the real cause turned up: patching
PPSSPP to log the guest PC/registers on every bad-memory-access event
showed every fault's `a0` register was exactly zero at
`init_heap_page`'s object-init loop (inlined into `mrb_gc_init`) — a
null `page` argument, despite `add_heap`'s `mrb_calloc` call having
just returned a real, valid, non-null pointer moments earlier in the
same run. The corruption was inside `mrb_calloc` itself
(`p = mrb_malloc(...); memset(p, 0, size); return p;`): GCC recognizes
this "memset then return the same pointer" idiom and, per its builtin
knowledge that a standard-conforming `memset()` always returns its
first argument, optimizes it into `return memset(p, 0, size);`. PSP's
`memset` is a kernel syscall under this toolchain, and PPSSPP's HLE
implementation of it (`sysclib_memset`,
`Core/HLE/sceKernelInterrupt.cpp`) returned `0` instead of the
destination pointer — unlike its sibling `sysclib_memcpy`, which
correctly returns `dst` — so GCC's optimization silently turned every
`mrb_calloc` call on this target into one returning PPSSPP's wrong `0`.
`sysclib_memmove` had the identical bug, fixed alongside it. Fixed by
adding the destination pointer as both functions' returned value,
matching their sibling `sysclib_memcpy`/`sysclib_strcat` and the real C
contract — `nix/patches/ppsspp-sysclib-memset-memmove-return-value.patch`.
**Verified: this is the fix that gets the EBOOT booting to
completion** — rebuilding PPSSPP with this patch and re-running the
identical EBOOT under normal `ppsspp-headless` JIT mode produces
`RPG2K_PSP_BOOT` → `RPG2K_PSP_MRUBY_OPEN ok` → `RPG2K_PSP_GAME_START
none not_found` → a continuous `RPG2K_PSP_BRINGUP` heartbeat, running
cleanly for over 850,000 frames with zero errors, stopped only by the
test harness's own timeout. See
[`docs/adr/0047-psp-memory-budget.md`](../../docs/adr/0047-psp-memory-budget.md)'s
P1 for the full nine-bug trail, including the eliminated theories along
the way. To reproduce any of this locally, run
PPSSPP's headless binary with `--log` (needed to surface the `sceIoWrite`
output). CI and a local build both go through this flake's own patched
`ppsspp` package output (see above) rather than nixpkgs' unpatched one —
`nix build '.#ppsspp'` puts it at `./result/bin/ppsspp-headless` (it finds
its own assets, so the working directory does not matter):

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
`LV_MEM_SIZE` therefore covers only LVGL's own widgets and internals, and the
decoded bitmaps stay in a third, uncapped pool as before. That pool is 256 KB,
cut down from an original 4 MB once P2 established what is actually left for
it to cover: neither the decoded bitmaps nor the LVGL partial-render draw
buffers (`psp.cxx`'s `g_buf1`/`g_buf2`, plain `std::vector`) come from it, and
the real game draws all of its own text through the RGSS `Bitmap`'s shinonome
blitter rather than LVGL's font system — only the idle bring-up screen's two
labels ever touch that. What is left is `lv_obj_t`/style bookkeeping for the
canvas/image/label widgets this port uses, plausibly tens of KB even for a
busy screen. Unlike the arena, LVGL's own default failure mode for pool
exhaustion (`LV_ASSERT_HANDLER`) is a silent `while(1);`, indistinguishable
from any other hang — `lv_conf.h` now points it at `psp_lvgl_assert_halt`
(`psp.cxx`), which writes an `RPG2K_PSP_LVGL_ASSERT` marker via `sceIoWrite`
before halting, so a pool that turns out too small shows up in the log
instead of as an unexplained stall.

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
