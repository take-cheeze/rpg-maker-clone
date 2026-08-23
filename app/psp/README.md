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
toolchain's own `$PSPDEV/bin/psp-fixup-imports` with a patched build; see
the bug trail lower in this section for why this EBOOT needs it to
actually boot. Configuring without it is a hard error, so there is no way
to get a silently mis-linked EBOOT out of this build:

```sh
scripts/build_psp_fixup_imports.bash
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
`psp-smoke` job boots the EBOOT under PPSSPP headless and checks that both
the boot marker and a frame-loop heartbeat appear, so a regression that
links but fails to boot — or boots but never pumps a frame — is caught
automatically; it has no project at `kGameDir`, so it only ever exercises the
idle path (`RPG2K_PSP_GAME_START none not_found`). The job is a
**required** check alongside `psp`: it ran with continue-on-error as a
holdover from when the EBOOT did not boot to completion under
PPSSPP-headless, but boot completes now (see below) and the frame loop
pumps thousands of heartbeats per run, so it gates like every other job.
Ten independent bugs were found and root-caused
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
P1 for the full trail, including the eliminated theories along
the way.

That state no longer reproduces on `master`. Boot now dies inside
`mrb_open()` again, on a **tenth bug** — this one in the toolchain, not
in this project or the emulator. Any C++ `throw` aborts in libgcc's
`uw_init_context_1` (`unwind-dw2.c`, `gcc_assert (code ==
_URC_NO_REASON)`), which fires when `uw_frame_state_for` cannot find an
FDE for the frame it is unwinding. mruby is built with the C++ exception
ABI — automatic, because gems here ship `.cxx` sources — so `MRB_THROW`
is a real throw and the first one during interpreter init is fatal. The
defect is not the CFI: `.eh_frame` is complete, correctly bracketed,
inside a `PT_LOAD`, and registered before `main()` by `crt0` → `_init` →
`frame_dummy` → `__register_frame_info`. It is libgcc's own
`fde_radixsort` — an 8-bit-digit radix sort needing four passes to cover
a 32-bit address, whose output is exactly the state after two. Measured
on this EBOOT: the array it produces has 1460 inversions against the
full `pc_begin` and **zero** against `pc_begin & 0xffff`, so it is
perfectly sorted on the low halfword. Every code address here is
`0x08xxxxxx`, so that ordering is useless and `search_object`'s binary
search misses every entry; a linear scan finds the FDE immediately.
Eliminated first, each by measurement rather than argument: the CFI data
itself, registration, `__builtin_return_address(0)`, libgcc's packed
unaligned read in `unwind-pe.h`, and `memmove`/`memset` through the
emulator's HLE. Worked around in `psp_unwind_fde.cxx`, which overrides
`__register_frame_info`/`_Unwind_Find_FDE`/`__deregister_frame_info` and
answers lookups from an index it sorts itself; with it, boot reaches
`RPG2K_PSP_MRUBY_OPEN ok` → `RPG2K_PSP_GAME_START` → a continuous
`RPG2K_PSP_BRINGUP` heartbeat again. Not upstreamed to pspdev yet, and
worth reporting there: nothing about it is specific to this project, and
it breaks C++ exceptions for every PSP binary this toolchain builds.
Since it is only reachable when something actually throws, it was
presumably dormant through the nine-bug trail above rather than newly
introduced.

### The `-O2` build is broken, and the build type is now pinned

`app/psp/CMakeLists.txt` pins `CMAKE_BUILD_TYPE` (through
`RPG2K_PSP_BUILD_TYPE`) because it used to be *ambient*: CMake initialises it
from the environment variable of the same name, and this repo's nix devshell
exports `CMAKE_BUILD_TYPE=RelWithDebInfo`. A local build inside `nix develop`
therefore got `-O2 -g -DNDEBUG` while the `psp` CI job, in a bare container
with no such variable, got an empty build type and no optimisation at all --
two undeclared, different builds of the same commit, which is how an
`-O2`-only failure went unnoticed.

At `-O2` the EBOOT used to halt on LVGL's TLSF assert
(`!block_is_free(block)` in `lv_tlsf_realloc`) during `lv_init()`.
**Resolved:** that was never an optimisation bug. It was bug 11 below --
`psp-fixup-imports` not repointing tail-call `j` instructions -- and
optimisation merely emits more tail calls, so it hit more mis-dispatched
stubs. With that fixed, `-O2` and `-Os` both boot to
`RPG2K_PSP_GAME_START` and hold a heartbeat, and the pin is now
`MinSizeRel`: every byte of `.text` is live RAM on this target, and `-Os`
saves 373 KB against `Debug`. The candidates ruled out along the way, each
by measurement, are kept because the eliminations are still sound:

- **The draw buffers.** `psp_display_create` reports its post-condition
  (`RPG2K_PSP_DRAWBUF`); both pointers are non-null and both sizes exact at
  `-O2`, and the assert fires before that marker is even reached. Not a
  recurrence of bug 7's `std::vector` miscompile.
- **Strict aliasing.** `lv_tlsf.c` type-puns block headers heavily, but
  `-fno-strict-aliasing` at `-O2` still asserts.
- **`lv_tlsf.c` itself.** Compiling only that translation unit at `-O0` with
  the rest at `-O2` does not fix it -- the failure *moves*, to near-null guest
  reads and a PPSSPP host segfault. TLSF's assert is a consistency check on
  headers living in memory anything can scribble on, so it is where the damage
  is noticed, not necessarily where it is caused.
- **`psp_unwind_fde.cxx`.** Compiling only it at `-O0` leaves the failure
  intact. (This does not establish that file is *correct* under optimisation --
  the `-O2` build never runs far enough to throw -- only that it is not the
  cause.)
- **PPSSPP's sysclib return values.** Near-null pointers at `-O2` are bug 9's
  signature (GCC exploiting its knowledge that `memset` returns its first
  argument against an HLE returning 0), so every sysclib function was
  re-audited: `memcpy`/`strcpy`/`strcat`/`strncpy` return their destination,
  `memset`/`memmove` do too via
  `nix/patches/ppsspp-sysclib-memset-memmove-return-value.patch`, and the four
  added by `nix/patches/ppsspp-sysclibforkernel-missing-functions.patch`
  (`tolower`/`strtoul`/`memchr`/`strncat`) are all correct. Not a recurrence.

The failure mode changes when unrelated code shifts the binary -- the same
layout sensitivity bug 7 showed -- so per-translation-unit bisection does not
converge on it. Whoever picks this up should probably reach for pool canaries
or guarded allocations rather than more bisecting. Until then `Debug` is
pinned, and the cost is measured and small: unoptimised `.text` is ~260 KB
larger, against a boot reporting 782 KB heap free, a 256 KB LVGL pool running
at 1.4%, and a 256 KB main stack at 6.4%.

### Bug 11: psp-fixup-imports did not repoint tail calls

`psp-fixup-imports` reorders import stubs and repoints the call sites that
target them, but the patched tool scanned only for `jal`. MIPS has a second
direct jump, `j`, which the compiler emits for a **tail call** -- any function
whose last act is calling the import. LVGL's delay hook in
`mruby-rgss/src/psp.cxx` is exactly that:

```c
void delay_cb(uint32_t ms) { sceKernelDelayThread(ms * 1000); }
```

It compiles to a bare `j sceKernelDelayThread` with no `jal` anywhere. This
EBOOT has **49 such sites against 1642 `jal`s**, and every one was left
pointing at its pre-reorder address, silently invoking whichever import the
regroup left sitting there.

The symptom was hard to read because it is layout-dependent. `delay_cb`'s tail
call landed on `sceIoRemove` in one build and `sceIoDread` in another, so
LVGL's once-per-frame *timing* call surfaced as a once-per-frame *filesystem*
syscall with nonsense arguments -- `a0 = 0x4a38`, the 19000us delay
reinterpreted as a path pointer -- and moved to a different, sometimes fatal,
syscall whenever unrelated code shifted the binary. Which is also why adding a
few lines of diagnostics to the guest could turn a working boot into an
emulator crash, and why this looked for a long time like layout-sensitive
memory corruption. Nothing was corrupt: the call simply went somewhere else.

What finally identified it was reading the guest's registers at the bad
syscall rather than reasoning from the call graph. `_unlink` sets `a0 = sp`
before calling `sceIoRemove`; the live `a0` was `0x00004a38` while `sp` was
`0x09fbf9a0`, which proved the call never came through `_unlink` at all,
despite `_unlink` being the only static `jal` to that stub.

Fixed by accepting `MIPS_OP_J` alongside `MIPS_OP_JAL` in
`patches/psp-fixup-imports-jal-relocation-aware.patch`; the rewrite already
preserves the opcode field, so a `j` stays a `j`. Verified: `delay_cb`'s tail
call now resolves to `sceKernelDelayThread`, the per-frame bogus `sceIoRemove`
and `sceIoDread` calls drop to zero, and 212623 real delays are issued across
a 1066-heartbeat run.

### Superseded: the "failed file operation on every frame"

With the two PPSSPP patches above in, the EBOOT boots to Nepheshel's title
screen and holds it, but the frame loop performs one failed file operation per
frame -- tens of thousands per run. Its identity changed when
`ppsspp-sysclib-strchr-strrchr.patch` landed:

- before: `sceIoDread` returning `BADF`, from pspsdk's `getdents`/`_lseekDir`
  (`libcglue/glue.c`) after a `sceIoDopen(ms0:/PSP/GAME/rpg2k/Fonts)` that
  fails because the directory does not exist. Its second argument was the
  emulator's `0xDEADBEEF` register poison, i.e. never set.
- after: `sceIoRemove` with a filename pointer PPSSPP cannot read. The call
  chain is `File.delete`/`File.unlink` -> `mrb_file_s_unlink`
  (`mruby-io/src/file.c:150`) -> `mrb_hal_io_unlink` -> `unlink` ->
  `_unlink_r` -> `_unlink` -> `sceIoRemove`, and `_unlink` passes the stack
  buffer `__path_absolute` filled in.

Both were the same thing, and neither was a file operation: bug 11 above.
The earlier caution about not attributing the change to either the emulator
or the guest was right to be cautious and wrong about the cause -- it was the
stub layout moving under an unrepointed tail call.

Two things make it worth chasing rather than ignoring. `mrb_sys_fail` raises
when the HAL call fails, and mruby here is built with the C++ exception ABI --
so a rescued Ruby exception per frame means a real C++ throw and unwind per
frame, through the FDE index `psp_unwind_fde.cxx` rebuilds. And no Ruby in
this tree calls `File.delete` per frame; the only non-test occurrence is a
one-off probe in `mruby-rgss/mrblib/lib.rb`. Something is reaching it that the
source does not obviously explain.

To reproduce any of this locally, run
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
  is decided and wired (mruby's whole heap lives in its own fixed arena, see
  `main.cxx`'s `mrb_basic_alloc_func` — LVGL's pool only aligns to 4 bytes on
  32-bit, too weak for mruby's word boxing, so sharing it is not an option
  the way it is on desktop). The size is now game-validated: Nepheshel's
  New Game pins the arena at ~12.0 MB steady-state under PPSSPP-headless
  (the title screen alone sits at ~4.3 MB), so the arena is 12 MB — 8 MB
  exhausted mid-map-load and the failed-allocation unwind corrupted VM state
  (see ADR 0047's P2 follow-up), and 16 MB starves the shared newlib heap.
  The `RPG2K_PSP_BRINGUP` heartbeat now reports the arena's own occupancy as
  `arena_used=` directly, next to free RAM and LVGL's pool high-water mark.
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
wired: mruby's entire heap lives in a fixed 12 MB arena of its own
(`main.cxx`'s `mrb_basic_alloc_func`) rather than sharing LVGL's pool (whose
TLSF only 4-byte-aligns on 32-bit — too weak for mruby's word boxing) or
growing unbounded on plain malloc, so the interpreter OOMs into a catchable
`NoMemoryError` instead of colliding with the decoded-bitmap heap. The size
is measured, not guessed: Nepheshel's New Game pins steady-state usage at
~12.0 MB (8 MB exhausted and corrupted mid-map; see ADR 0047's P2 follow-up),
while 16 MB takes RAM the decoded-bitmap/newlib heap needs. `lv_conf.h`'s
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
free RAM, `lvgl_used`/`lvgl_max` are LVGL's pool, and `arena_used=` is the
mruby arena's occupancy once a game is actually running.

For a packed RPG Maker XP/VX/VX Ace title,
[`scripts/rgssad_unpack.rb`](../../scripts/rgssad_unpack.rb) unpacks
`Game.rgssad`/`.rgss2a`/`.rgss3a` into a loose file tree in place — the
loose-file-first loaders already prefer it over the archive, so this avoids
the whole-archive-resident-in-RAM read the packed form forces (see the ADR's
Finding 2). Excluding the packed archive from a given PSP deployment, so it
is never opened at all, is still a manual step the unpacker itself doesn't
take for you.
