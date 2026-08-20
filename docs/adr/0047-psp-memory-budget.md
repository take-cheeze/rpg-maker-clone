# 47. PSP memory budget

Date: 2026-08-14

## Status

Proposed

## Context

ADR 0010 landed the PSP as a **HAL bring-up** EBOOT — display and input only,
no mruby interpreter, no game assets. Its stated next slice is "wiring
`libmruby.a` into the EBOOT link and starting the real `RPG2k` scene tree."
That ADR dismissed the memory-budget work ADR 0007 had to do for the Wio
Terminal: "Because the PSP has ~24 MB of RAM, the gem-trimming and
streaming-asset work that ADR 0007 needs for the Wio Terminal is not expected
to be necessary here; the full gem set should fit."

That claim is about gem *code* size, not the per-title asset memory a real
game materializes at runtime, and it predates the interpreter actually being
linked. Before that slice lands, this ADR checks the assumption against the
code paths that will run once mruby is wired in — the same "budget before
code" discipline ADR 0007 used for the Wio Terminal ("Everything below the
Decision heading is a design record and roadmap. No runtime or build code
changes ship with this ADR").

### Finding 1 — mruby's heap defaults to sharing LVGL's pool, not a separate one

mruby 4.0 removed per-state allocators; a program now supplies one global
`mrb_basic_alloc_func`. On desktop, `src/main.cxx:638` defines it to route
through `lvallocf` (`src/main.cxx:466`), which calls `lv_malloc`/`lv_realloc`/
`lv_free` — so **all** of mruby's live heap (the game's objects, strings, the
parsed LCF database, everything) is accounted inside LVGL's `LV_MEM_SIZE`
pool, not a separate arena. Emscripten is the one target that opts out of this
(`src/main.cxx:628`, guarded by `#ifndef __EMSCRIPTEN__`), and only because
LVGL's TLSF pool aligns to 4 bytes on wasm32 while mruby's word boxing needs
16-byte alignment — a target-specific, deliberate exception, not the default.

`PSP_BUILD` is not `__EMSCRIPTEN__`, so **unless the interpreter-linking slice
adds a new exception, the PSP inherits the shared-pool behavior automatically**
the same way the desktop does. That contradicts the assumption baked into
`app/psp/lv_conf.h`'s own comment: "far below the desktop's 16 MB so it leaves
room for the mruby heap ... in later slices" — which reads as if the mruby
heap lives *outside* `LV_MEM_SIZE`. (That comment is also out of date on its
own terms: `include/lv_conf.h`'s desktop `LV_MEM_SIZE` is 64 MB today, not
16 MB — a sign this number was set once, early, and not revisited.) The PSP's
current pool is 4 MB. If the shared-pool default holds, 4 MB has to cover
every live LVGL widget *and* the entire mruby object graph for a running game
— almost certainly too small once a real database and map are loaded. Decoded
bitmaps are *not* part of that 4 MB, for reasons that turned out to matter
enough to be their own finding — see Finding 3.

**Host-side proxy measurement (not a device number, see the caveat below):**
built this repo's own `3rd/mruby` submodule into a plain host `mrbc`/`mruby`,
compiled `mruby-rpg2k` + `mruby-lcf` + `mruby-rgss`'s mrblib the way the gem
system actually does (concatenated per gem, `mrbc -B` C-array form), and
loaded the resulting bytecode via `mruby -b` (pre-compiled load, not
source-compiled — see the correction below) to measure `/proc/self/status`
RSS before/after. Defining every class and method those three gems' mrblib
contains costs **~1.2–1.4 MB of live heap**, before any database, map, or
bitmap is touched. `sizeof(struct RString)` is 40 B and `sizeof(mrb_value)` is
8 B on this x86-64 host; mruby's own `mrb_static_assert(sizeof(RVALUE) <=
sizeof(void*)*6)` means these roughly halve on the PSP's 32-bit MIPS, so the
real device number is plausibly lower, but not by an order of magnitude —
**this alone is already close to a third of the current 4 MB pool.**

An earlier pass at this number (compiling the mrblib *from source* via
`mruby script.rb` instead of pre-compiled bytecode) measured ~5.3 MB and is
wrong for this target: that path pays the parser/AST/codegen compiler's own
transient memory, which doesn't apply here — the actual PSP build compiles
mrblib to bytecode ahead of time via `mrbc` and links it in, matching the
`-b` measurement, not the from-source one.

### Finding 2 — whole-file asset loads, sharper than ADR 0007's version but not gone

ADR 0007 called whole-file asset loading "the real blocker" for the Wio
Terminal's 192 KB ceiling. The PSP's 24 MB ceiling is far more forgiving, but
the same code paths still load whole files into single mruby `String`s, and at
least one of them can still blow the budget outright:

- `mruby-rpg2k/mrblib/main.rb:543-611` reads the LCF database (`.ldb`), map
  tree (`.lmt`) and each map (`.lmu`) whole via `File.open(...).read`. This is
  the path the PSP's next slice actually exercises (RPG2k). These files are
  typically hundreds of KB to a few MB for a real game — plausible to fit
  inside a well-sized budget, but unmeasured on this target.
- `RPGXP::RGSSAD.open` (`mruby-rpgxp/mrblib/rgssad.rb:60-61`) reads an
  **entire** packed `Game.rgssad`/`.rgss2a`/`.rgss3a` archive into one mruby
  `String` before anything is decoded, and `RGSSData#initialize`
  (`mruby-rpgxp/mrblib/rgss_data.rb:242-244`) keeps that `RGSSAD` object — and
  so the whole `@data` string — alive in `@archive` for the database's entire
  lifetime, not just for the duration of `open`. A released RPG Maker XP/VX
  game routinely packs tens of MB of graphics and audio into that single
  archive — comfortably larger than the *entire* 24 MB budget by itself,
  before LVGL, the mruby VM, or any decoded bitmap is counted. RPG2k bring-up
  doesn't touch this path, so it isn't blocking the next slice, but it is a
  documented cliff for the day an XP/VX game is pointed at the PSP build, not
  something to discover as a crash on real hardware.

  This one already has a low-cost fix available, because the loader was built
  to prefer loose files over the archive: `read_object`
  (`rgss_data.rb:294-300`) checks `File.exist?` before ever touching
  `@archive`, and `Bitmap#init_from_archive`
  (`mruby-rgss/mrblib/lib.rb:606-620`) is likewise only a fallback after the
  loose-file search misses ("loose shadows packed, as in RGSS" —
  `mruby-rgss/mrblib/lib.rb:29`). So **pre-unpacking a packed game's archive
  into a loose `Data/`/`Graphics/`/`Audio/` tree on the Memory Stick needs no
  interpreter or gem code changes at all** — the existing readers already take
  the loose path first. The unpack itself is naturally an *offline* step (run
  the existing `RGSSAD` reader on a desktop build, where RAM is not a
  constraint, and write each entry out as a file); nothing about it requires
  new PSP-side code either.

  The catch: `RGSSData#open_archive` (`rgss_data.rb:337-345`) calls
  `RGSSAD.find`, which looks for `Game.rgssad`/`.rgss2a`/`.rgss3a` by *path
  existence* and unconditionally opens (reads whole file) whichever one it
  finds — regardless of whether every entry it contains is already shadowed by
  a loose file. Unpacking without also removing the packed archive from the
  PSP game directory buys nothing: `open_archive` still eagerly reads the
  whole thing into memory, just to have it sit unused. So the fix is really
  two parts, both deployment-time rather than code: ship the unpacked tree,
  and *don't* ship (or delete on first run) the `Game.rgssad`/`.rgss2a`/
  `.rgss3a` file alongside it.

  A streaming/seekable `RGSSAD` reader (open a `File` handle and seek+decrypt
  each entry on demand instead of slicing a fully-loaded `@data`) is a fallback
  option that avoids duplicating storage on the Memory Stick, but it is new
  code, whereas the unpack is not — so it is only worth it if Memory Stick
  space (not RAM) turns out to be the binding constraint for a given release.

### Finding 3 — decoded bitmaps live in a third pool, not "LVGL's image cache"

Corrected from an earlier pass at this ADR, which described this as an LVGL
image-cache sizing problem. It isn't — there is no LVGL image cache in play
here at all, checked directly against how a decoded bitmap actually reaches
the screen:

- `Bitmap::buffer` (`mruby-rgss/src/lib.cxx:167-181`) is a plain
  `std::vector<uint8_t>`, sized `width * height * bytes-per-pixel` and
  allocated the moment a `Bitmap` is constructed. `bmp_decode_into`
  (`lib.cxx:1254-1315`) decodes the source image via stb_image into a
  `std::shared_ptr` scratch buffer (freed via its `stbi_image_free` deleter
  the moment the function returns — confirmed not a leak) and `memcpy`s the
  result into that `Bitmap::buffer`, which then stays resident for the
  sprite's lifetime, same as the original finding said.
- What the original finding got wrong is *where* that memory comes from.
  Every call site (`lv_canvas_set_buffer(obj, bmp.buffer.data(), w, h,
  format)`, e.g. `lib.cxx:3158/3555/4034/4692`) hands LVGL's canvas widget a
  raw pointer into memory `Bitmap` already owns — LVGL never allocates,
  caches, or frees that buffer itself. `std::vector`'s backing storage comes
  from the plain C++ global allocator (`operator new`), and neither this
  project nor stb_image (`STBI_MALLOC` is never redefined, confirmed
  by grep) overrides it to route through `lv_malloc`. So decoded bitmap
  pixels — likely the single largest category of "asset memory" in this
  ADR's Context — **never touch `LV_MEM_SIZE` at all.** They come out of the
  plain C runtime heap (newlib `malloc` on the PSP), a third pool alongside
  LVGL's pool (Finding 1: LVGL objects, and mruby's whole object graph if the
  shared-allocator default holds) and the stack/statics (Finding 4).
- This cuts both ways. It's good news for Finding 1's pool-sizing question —
  bitmaps don't compete with mruby's live objects for the same 4 MB — but
  it means this third pool currently has **no cap of its own at all**, only
  whatever's left of the PSP's ~24 MB after everything else. RPG2k assets
  (charsets, tilesets) are modest; XP/VX assets (a 640×480 background) decode
  to much larger buffers, and nothing currently limits how many can be live
  at once.
- The P1 heartbeat (`app/psp/main.cxx`) already has visibility into this
  without further instrumentation: `sceKernelTotalFreeMemSize` reports
  *actual* free RAM, so once mruby is linked and real bitmaps are loaded, the
  gap between that number and `lv_mem_monitor`'s LVGL-pool figures *is* this
  third pool's consumption — no new code needed to observe it, just correct
  expectations about what it's showing.

### Finding 4 — main-thread stack is still bring-up-sized

`app/psp/main.cxx` uses pspsdk's default main-thread stack (no
`PSP_MAIN_THREAD_STACK_SIZE_KB`), sized for the current LVGL-only loop. ADR
0007 already flagged mruby's init-time recursion as a stack risk on
constrained targets; nothing has measured it for the PSP yet because the
interpreter isn't linked.

### Finding 5 — mrbc's bytecode debug info costs live RAM; native C debug info and `-O0` do not

`enable_debug` (called for every build variant in `build_config.rb` — host,
wio, psp, emscripten) does three things, and only one of them is a real,
unaddressed cost:

- **It appends `-O0` to every compiler's flags.** This sounds like exactly
  the kind of thing that would bloat and slow down the PSP build, but
  **every one of those four build blocks already strips it back out**
  immediately afterward (`[conf.cc, conf.cxx].each { |t| t.flags =
  t.flags.flatten.delete_if { |v| v == '-O0' } }`, present in the host,
  wio, psp, and emscripten blocks alike), leaving the toolchain's normal
  `-O3`. Checked directly against `3rd/mruby`'s `tasks/toolchains/gcc.rake`
  and confirmed by rebuilding this project's own mruby core both ways: with
  `-O0` surviving, `.text` is 1,612,347 B; with it stripped (this repo's
  actual, current setting), 1,301,995 B. **The PSP build is not running
  unoptimized code.** (An earlier pass at this ADR's research got this
  wrong — flagged `-O0` as a live issue after testing an isolated mruby
  config that didn't include this project's existing strip. Recorded here so
  it isn't rediscovered.)
- **It appends `-g3` to every compiler's flags**, and nothing strips that
  back out. This is real native (DWARF) debug info, but confirmed via
  `readelf` on a trivial ELF that every `.debug_*` section has virtual
  address `0` and sits outside all `PT_LOAD` segments — never mapped into
  the process. Same ELF format on PSP's MIPS target: **`-g3` costs
  `EBOOT.PBP`/build-artifact file size only, never runtime RAM.** Confirmed
  the scale on this project's actual `libmruby.a`: stripping debug symbols
  takes it from 33.1 MB to 2.97 MB. Not nothing for the build artifact, but
  out of scope for a *RAM* budget ADR.
- **It appends `-g` to `mrbc`'s own compile options**
  (`Command::Mrbc#initialize`'s default is `"-B%{funcname} -o-"`, nothing
  else) — separately from the two points above, and *this* one is real and
  unaddressed anywhere in the build. It embeds line-number/local-variable
  debug tables in the compiled Ruby bytecode for every gem's mrblib (the
  game's own Ruby, not mruby's C core). Unlike native DWARF, `mrb_load_irep`
  parses these tables into live heap structures the moment the interpreter
  boots: measured by loading the same rpg2k+lcf+rgss bytecode from Finding
  1's benchmark both ways via `mruby -b`, `-g` costs **~240–350 KB of live
  RAM** on top of a ~15% larger compiled-bytecode file (538,259 B → 621,734
  B for the combined mrblib). `mruby-strip` (mruby's own `mruby-bin-strip`
  gem, not currently part of this project's gem set) removes it and gives
  byte-identical output to compiling without `-g` in the first place —
  confirmed directly, both in file size and in loaded RSS.

## Decision

Answer these questions, and capture real numbers, as part of — not after —
the interpreter-linking slice, in this order:

- **P1 — measure before sizing.** Substantially done — boot now completes
  under PPSSPP-headless and the idle-path heartbeat captures real device
  numbers (see below); still partial in that the *mruby* share only
  reflects the idle path until a real game runs on-device. Finding 1's
  ~1.2–1.4 MB and
  Finding 5's ~240–350 KB figures are a host x86-64 proxy, not device
  numbers — still worth having over pure guesswork, but not a substitute for
  the device side. That side is now landed too: the bring-up EBOOT's
  `RPG2K_PSP_BRINGUP` heartbeat (`app/psp/main.cxx`) reports
  `sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize` (the device's actual
  free RAM) and `lv_mem_monitor`'s current-use and `max_used` high-water mark
  for LVGL's pool, once a second, into the same log CI's `psp-smoke` job
  already captures — no interpreter needed to start measuring the HAL's own
  footprint. The interpreter-linking and scene-tree slices have since landed
  too (`RPG2K_PSP_MRUBY_OPEN`, `RPG2K_PSP_GAME_START`) — `app/psp/main.cxx`
  constructs `RPG2k` and drives it when a project is present at its fixed
  `kGameDir` (see `app/psp/README.md`). What's still missing: CI's
  `psp-smoke` job has no project there, so it only ever exercises the idle
  path — the *mruby* share of the pool remains unmeasured on-device until a
  real game database and map actually runs there, on real hardware or an
  emulator with a Memory Stick image. **The emulator side is now
  unblocked**: the idle path's own heartbeat numbers are captured below,
  and CI's `psp-smoke` job (still no project at `kGameDir`) exercises the
  same idle path automatically on every push.
  Nine independent bugs were found and root-caused on this path; eight
  of them fixed, the remaining one (bug 3, pspsdk's own upstream bug) no
  longer reachable — **boot now completes**. In the order the EBOOT hits
  them:
  1. **Fixed.** pspsdk's `sysclib_snprintf`/`sysclib_sprintf` HLE stubs are
     only partially implemented under PPSSPP-headless and left emulator
     state corrupted enough to crash a few syscalls later — `main.cxx` now
     builds every marker/heartbeat string with a small libc-free `StrBuf`
     instead of `std::snprintf`.
  2. **Fixed, PPSSPP-side.** `sceKernelCreateLwMutex`
     (`Core/HLE/sceKernelMutex.cpp`) dereferenced its caller-supplied
     workarea pointer without validating it first, unlike every sibling
     LwMutex function in the same file — a guest passing `workareaPtr=0`
     turned that into a null-pointer write that segfaulted the *host*
     `ppsspp-headless` process (confirmed with `gdb` against a core dump,
     same crash address across independent runs). Not yet upstreamed to
     `hrydgard/ppsspp`; `flake.nix`'s `ppsspp` package output carries the
     fix as a local patch (`nix/patches/
     ppsspp-lwmutex-workarea-validate.patch`).
  3. **Real bug, confirmed present in pspsdk, but no longer reachable on
     this boot path — not fixed, and no longer blocking anything by
     itself.** With bugs 1–2 out of the way, a `workareaPtr=0` genuinely
     came from the guest side, not host memory corruption — traced to
     pspsdk's own `src/libcglue/lock.c`, where
     `__retarget_lock_init_recursive` calls `malloc()` for a new lock
     struct with no null-check before dereferencing it, triggered by
     `global_stdio_init`'s lazy lock creation on this EBOOT's very first
     stdio use (`detect_game()`'s `fopen` probes). Confirmed present in
     both the pspdev/pspdev container's shipped `libcglue.a` and a
     from-scratch rebuild of unmodified pspsdk source (ruling out a stale
     container library as the cause — an earlier, since-retracted theory
     in this section blamed a stale library and a downstream JIT/heap
     crash; both were artifacts of this investigation's own diagnostic
     instrumentation perturbing timing, not genuine behavior). That
     `malloc()` was failing because of bug 5 below (the same broken
     `_sbrk()` heap init) — with bug 5 fixed, `malloc()` for the lock
     struct now succeeds and this null-check gap simply never triggers on
     this boot path anymore (confirmed: re-tested the full boot with bug
     5's fix applied, zero `ILLEGAL_ADDR=sceKernelCreateLwMutex` calls,
     versus dozens before). The missing null-check is still a real latent
     bug in pspsdk itself and worth reporting upstream, but it is not
     something this repo needs to work around right now.
  4. **Fixed, PPSSPP-side.** The interpreter's `mfic`/`mtic` (Allegrex "move
     from/to interrupt controller", `Core/MIPS/MIPSInt.cpp`) were pure
     no-ops. pspsdk's `pspSdkDisableInterrupts()`/`EnableInterrupts()`
     (`src/sdk/interrupt.S`) are built directly on these two instructions,
     used to guard its own non-reentrant C-runtime state (the `pte_os*`/
     newlib glue in `src/libpthreadglue/osal.c`) without syscall overhead;
     with them doing nothing, those critical sections gave no real
     protection under PPSSPP. Not yet upstreamed; `nix/patches/
     ppsspp-mfic-mtic-interrupt-mask.patch` applies it locally alongside
     the LwMutex patch.
  5. **Fixed, this repo's build config.** `app/psp/CMakeLists.txt` linked
     `pspkernel` before `pspuser`. Both static libraries provide
     `sceKernelCreateCallback`, `sceKernelSleepThreadCB`, and
     `sceKernelMaxFreeMemSize` as distinct `ForKernel`/`ForUser` NIDs; with
     `pspkernel` first, `ld` kept its `ForKernel` stub for all three under
     `--allow-multiple-definition`'s first-definition-wins rule, so this
     user-mode EBOOT's imports named the kernel-mode NID for each. PPSSPP's
     loader has no HLE implementation registered under those modules for a
     plain homebrew EBOOT, so every call silently returned
     `SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED` — none of the three's
     callers (`setup_callbacks`'s `callback_thread`, and `_sbrk`'s
     heap-size probe) check the return value. This was the actual cause of
     the EBOOT hanging under PPSSPP-headless past `RPG2K_PSP_BOOT`:
     `_sbrk()` re-ran its heap-init probe on every call forever, so the
     first real `malloc()` never returned. Linking `pspuser` first fixed
     it — confirmed via PPSSPP's syscall log: the "unknown syscall"/failed
     LwMutex counts, which used to run into the hundreds of thousands over
     a 15s boot attempt, dropped to zero.
  6. **Fixed, via a patched pspsdk host tool.** With bug 5 fixed,
     `psp-fixup-imports` (pspsdk's post-link import-table tool) warned
     `stubs out of order` on this binary. It requires every stub reference
     to a given PSP module to be physically contiguous in the linked
     binary's import metadata. When out of order, the tool still marked
     entries processed but assigned some of them the wrong
     `(module, function)` index, so PPSSPP resolved several genuine,
     correctly-named imports (confirmed present as real `ForUser`-module
     NIDs) as if they belonged to an unrelated module, and calls into them
     returned `SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED` — again silently,
     and this was what hung boot just past bug 5's fix.

     Traced to its actual source, not just its symptom: `app/psp/main.cxx`
     alone accounts for the overwhelming majority of this EBOOT's ~88
     total PSP imports across 15 modules; `mruby-rgss/src/psp.cxx` (built
     into `libmruby.a`, the only other object file in the whole archive —
     all 160 of them — that calls a raw PSP syscall at all) contributes
     just 9, of which 2 (`sceIoWrite`, `sceKernelDelayThread`) overlap with
     `main.cxx` and 7 are unique to it. A minimal, hand-written pspsdk
     homebrew calling into three different modules (`ThreadManForUser`,
     `sceDisplay`, `sceCtrl`) from a single file — deliberately structured
     like `main.cxx`'s own mix — built clean with no warning, which ruled
     out "any file touching multiple modules" as the trigger, and matched
     `psp.cxx`'s own 7 module-unique calls also causing no trouble on
     their own. The actual splits are things like `ThreadManForUser`:
     `setup_callbacks()` calls `sceKernelCreateThread`/`sceKernelStartThread`
     once, early, and the separate, ongoing `RPG2K_PSP_BRINGUP` heartbeat
     calls `sceKernelGetThreadStackFreeSize` (same module) once per second
     from inside the main loop — two genuinely different call sites,
     necessarily far apart in `main.cxx`'s own control flow, with unrelated
     modules' calls (`IoFileMgrForUser`, `SysMemUserForUser`, ...) between
     them. Re-linking `main.cxx` at `-O0` did not change the warning either
     (ruled out compiler reordering). So this was never an accident
     reorder-away-able fix: it reflects how this EBOOT's own logic is
     actually laid out, not a stray ordering slip — no restructuring of
     which compilation units call which PSP modules would have avoided it
     either, only deferred it to the next place two calls to the same
     module happen to land far apart.

     A patch that just stably regroups the tool's `(stub_addr, nid)`
     metadata by owning module was written and tested first, and found
     **unsafe**: `stub_addr` doubles as the fixed trampoline address every
     `jal` instruction elsewhere in the binary already targets at link
     time, so moving which function's metadata occupies which slot
     decouples the two — confirmed by testing it, which produced a binary
     where `sceKernelCreateThread` and `sceIoRemove` both resolved to the
     same trampoline address, and the guest's own crt0 sequence ended up
     calling `sceIoRemove("user_main")`. The actual fix does the full
     relocation-aware rewrite that implies: after grouping, scan every
     executable section for `jal` instructions targeting a slot that
     moved, and repoint each one at the function's new address (an
     ET_EXEC binary carries no relocation entries left to do this through
     any other way). `patches/psp-fixup-imports-jal-relocation-aware.patch`
     (pinned against a specific pspsdk commit, matching what
     `pspdev/pspdev:latest`'s own prebuilt tool was built from) carries the
     fix; `scripts/build_psp_fixup_imports.bash` fetches pspsdk at that
     pin, applies it, and drops the rebuilt tool in place of the
     toolchain's own copy — wired into the `psp` CI job
     (`.github/workflows/build.yml`) ahead of `psp-cmake`/`cmake --build`.
     Confirmed on this project's own EBOOT: 88 imports across 15 modules,
     78 of which needed to move, 1620–1625 `jal` instructions repointed to
     match (the exact count moves slightly run to run with unrelated
     binary layout changes, e.g. bug 5's fix shrinking the .bss zero-fill
     shifted a few unrelated addresses), zero `stubs out of order`
     warnings afterward.

  With bug 6 fixed, this EBOOT boots dramatically further than at any
  earlier point on this whole P1 trail: past `RPG2K_PSP_BOOT`, through
  `_sbrk`'s heap init (correctly allocating the full requested size this
  time, confirmed via PPSSPP's own memory-partition log line), through
  `mrb_open`, into real LVGL widget creation in `build_ui()`. It then hit
  a **seventh bug — fixed**: LVGL's builtin TLSF allocator's
  `lv_tlsf_realloc` (`3rd/lvgl/src/stdlib/builtin/lv_tlsf.c`) asserted
  `block already marked as free` — a use-after-free/double-free detector,
  not a sizing issue (confirmed: bumping `LV_MEM_SIZE` 8x, from 256 KB to
  2 MB, made no difference at all to whether or where the assert fired,
  which a genuine capacity problem would not do). Root-caused with a
  print-capable `LV_ASSERT_HANDLER` (routed through
  `lv_log_register_print_cb`, printing LVGL's own formatted file+line
  assert message instead of guessing from a return address) to
  `psp_display_create` (`mruby-rgss/src/psp.cxx`): the two LVGL
  partial-render draw buffers were sized with
  `std::vector<uint8_t>::assign(n, 0)`, which is broken on this pspdev
  g++/libstdc++ build specifically when growing an empty (0-capacity)
  vector — it allocates the buffer correctly but leaves the vector's own
  begin pointer null while its end pointer holds the real allocated
  address, so `.data()` comes back null and `.size()` comes back as that
  allocated pointer's raw integer value reinterpreted as a count
  (confirmed in isolation against the same toolchain: `vector(n, 0)`'s
  constructor and `vector::resize(n)` do not share the bug, only
  `assign()` does). The null/wild pointer fed straight into
  `lv_display_set_buffers` either tripped its own `buf1 != NULL` assert
  directly, or — on binary layouts where the corrupted pointer wasn't
  exactly null — let LVGL and `flush_cb` write display pixels through it
  into unrelated memory, corrupting LVGL's own TLSF pool; that corruption
  is what the `block already marked as free` assert actually traced back
  to. Fixed by switching both buffers to `.resize(n)`, confirmed not to
  share the bug and to zero-initialize the same way.

  With bug 7 fixed, the EBOOT boots past display creation and into
  `mrb_open`'s GC init before hitting an **eighth bug, fixed**: PPSSPP
  reported `Bad memory access detected! 00000014` (or a nearby small
  address) — a near-null read — inside `mrb_gc_init`, and separately
  spammed `Unknown syscall: Module: '(unknown)' (module: 255 func:
  4095)` (PPSSPP's own "this NID has no HLE implementation" sentinel)
  dozens of times during boot. Three earlier passes at this
  misdiagnosed it — as PPSSPP JIT mistranslation, then as a
  timing-sensitive guest-side race, then as a boxed-`mrb_value`/
  `const char*` type confusion inside mruby — each building on a real
  observation but drawing the wrong conclusion from it (see git history
  of this file for the full, now-superseded trail; not worth carrying
  forward here since the actual cause turned out to be much simpler
  than any of the three).

  A fourth pass found the real cause with a verbose trace through this
  project's own JAL-relocation-aware `psp-fixup-imports`
  (`patches/psp-fixup-imports-jal-relocation-aware.patch`), temporarily
  instrumented to print exactly which function landed at which final
  stub address after its grouping pass. That trace proved the import
  grouping itself is fully correct (every function lands under its real
  SCE module name, contiguous, matching the intended reorder one-for-
  one) — the "sceKernelUnlockLwMutex" label the third pass's
  `psp-nm`/`psp-objdump` cross-reference had relied on was stale: those
  tools' symbol tables reflect each stub's *original*, pre-reorder
  address, not the address the tool's own grouping pass (deliberately)
  moved its content to, so matching a runtime fault address against
  that symbol table pointed at the wrong function entirely. The actual
  function sitting at the faulting slot, per the fresh trace, was
  `strtoul` (`SysclibForKernel`, NID `0x6A7900E1`) — and cross-checking
  all sixteen `SysclibForKernel` imports this EBOOT pulls in against
  PPSSPP's own `Core/HLE/sceKernelInterrupt.cpp` showed PPSSPP
  implements twelve of them but is missing four: `strtoul`
  (`0x6A7900E1`), `strncat` (`0xD3D1A3B9`), `memchr` (`0x68A78817`),
  and `tolower` (`0x3EC5BBF6`) — the exact four functions PPSSPP's
  loader logs found and cross-checks correctly, but for which the
  loader's own runtime dispatch has no HLE handler.

  Every one of those four functions is a call this EBOOT (via mruby's
  vendored `gc.c`/`class.c`/`string.c`/newlib itself) makes routinely —
  calling any of them under PPSSPP-headless silently did nothing and
  returned whatever garbage happened to already be in the return-value
  register, rather than the guest's intended `memcpy`-adjacent effect.
  That is what produced this whole bug's signature symptoms: the
  recurring near-null reads (`0x0`/`0x4`/`0xc`/`0x14`, which do
  coincidentally match `mruby/boxing_word.h`'s `Qnil`/`Qfalse`/`Qtrue`/
  `Qundef` constants, as the third pass found — but as a coincidence of
  what garbage ended up in play, not evidence of an actual boxed-value/
  pointer type confusion) and the eventual fatal `strlen(0000011e)`
  call the third pass also found, all downstream fallout from earlier
  `strtoul`/`strncat`/`memchr`/`tolower` calls silently no-opping rather
  than doing their real job — not a bug in this EBOOT's own code, in
  mruby, or in the fixed-arena allocator (ADR 0047's P2) at all.

  Fixed by adding all four missing functions to PPSSPP's own
  `SysclibForKernel` HLE table, matching the existing entries'
  established style (`Memory::IsValid*`-guarded, `hleLogVerbose`-wrapped
  host calls into the real libc function) —
  `nix/patches/ppsspp-sysclibforkernel-missing-functions.patch`. Not
  upstreamed to `hrydgard/ppsspp` yet, but a strong upstream candidate:
  nothing about this gap is specific to this project, and PPSSPP's own
  choice to implement twelve of the sixteen `SysclibForKernel` NIDs
  clearly intends to cover this module, just incompletely. Verified:
  rebuilding PPSSPP with this patch and re-running the identical EBOOT
  drops the `Unknown syscall` count from ~90 to 1 and eliminates the
  `Bad memory access` flood entirely; `RPG2K_PSP_MRUBY_OPEN` still isn't
  reached (see bug 9), but the specific symptoms bug 8 was named for —
  the near-null reads and the `strlen(0000011e)` fault — are gone.

  Whether real hardware shares bug 8 is unknown but plausible in one
  narrow sense (any *other* SysclibForKernel NID a future change starts
  calling that PPSSPP still doesn't implement would misbehave the same
  way there too, per real firmware's own behavior for a genuinely
  missing kernel export) — moot for the specific four functions this
  pass fixed, since real firmware does implement them. The P1 device
  numbers above remain unconfirmed on the emulator and untried on
  hardware.

  With bug 8 fixed, this EBOOT reached a **ninth bug — fixed, the last
  blocker on this whole P1 trail**: `3rd/mruby/src/gc.c`'s
  `mrb_assert(is_gray(obj))` inside `gc_mark_children` fired for real (a
  genuine `assertion "((obj)->gc_color == 0)" failed` message, printed
  to stderr via the same `sceIoWrite` path every other marker in this
  trail uses — the first time this whole investigation reached a *real,
  unambiguous mruby-internal assertion message* rather than a raw fault
  address to reverse-engineer). `is_gray`/`GC_GRAY` expects every object
  handed to `gc_mark_children` to still be in the
  just-pushed-onto-the-mark-stack GRAY state; this one was not.

  Several deep trace passes (temporary instrumentation in
  `3rd/mruby/src/gc.c` and `app/psp/main.cxx`, none kept) ruled out a
  string of plausible-looking explanations with direct evidence before
  the real cause turned up — worth recording, since each elimination
  narrowed the search and the pattern (misdiagnose, get real evidence,
  correct course) is this whole trail's own method working as intended,
  same as bug 8's three earlier passes:

  - Not the fixed arena returning null for `add_heap`'s allocation
    (traced directly; always succeeded, with megabytes of headroom).
  - Not a null `mrb_heap_page` in the general case (`add_heap`'s own
    `mrb_calloc` result printed directly on several runs — always a
    real, valid, non-null pointer).
  - A real, reproducible premature-heap-page-reclamation mechanism *was*
    found under `MRB_GC_STRESS` (forces a full GC before every
    allocation): a freshly-`init_heap_page`'d page, whose every slot
    starts `tt == MRB_TT_FREE` from initialization rather than genuine
    death, is indistinguishable from "swept clean" to `is_dead()` and
    can be reclaimed by a sweep before anything is ever allocated from
    it. This is a real, latent bug class in `incremental_sweep_phase`'s
    dead-page detection, worth keeping in mind for the future — but
    proved not to be bug 9's actual (non-stress) trigger.
  - `MRB_HEAP_PAGE_SIZE` (this target's memory-saving override, 256
    instead of the default 1024) was ruled out directly: rebuilding with
    the desktop/wasm-matching default reproduced bug 9 identically.
  - `mrb_arena_alloc` itself was confirmed completely healthy across the
    entire crash window with unconditional (not size-filtered)
    instrumentation — every allocation, including the specific 16-byte
    `iv_rehash` call a prior pass had (wrongly) suspected of
    deterministically returning null, succeeded with a real, valid,
    sane pointer. Zero `mrb_arena_free` calls happened before the crash
    either, ruling out a use-after-free via this project's own
    allocator.

  **The actual cause**, found by patching PPSSPP itself to log the guest
  program counter and registers on every "bad memory access" event
  (mirroring how bug 7's TLSF diagnosis and bug 8's crash log were each
  solved by getting real dynamic data instead of guessing from static
  code or stale symbol tables): every fault's `a0` register — the first
  argument to whatever function was executing — was exactly zero, and
  the guest PC symbolized cleanly (regular compiled code, not an import
  stub — the stale-symbol trap that misled three passes on bug 8 does
  not apply here) to `init_heap_page`'s object-initialization loop,
  inlined into `mrb_gc_init`. That loop's `page` argument was zero —
  despite `mrb_arena_alloc` printing the *correct*, non-null pointer
  (`0x08c31d20`) as `add_heap`'s `mrb_calloc` call's own return value,
  moments earlier, in the very same run.

  The corruption happens inside `mrb_calloc` itself
  (`3rd/mruby/src/gc.c`):

  ```c
  p = mrb_malloc(mrb, size);
  memset(p, 0, size);
  return p;
  ```

  GCC recognizes the "call `memset(p, ...)`, then `return p`" idiom and
  — per its builtin knowledge that a standard-conforming `memset()`
  always returns its first argument — optimizes this into the
  equivalent of `return memset(p, 0, size);`. That is a valid,
  semantics-preserving transformation for any real `memset`. But PSP's
  `memset` is a *kernel syscall* (`SysclibForKernel`, NID `0x10F3BB61`)
  under this toolchain, and PPSSPP's HLE implementation of it
  (`Core/HLE/sceKernelInterrupt.cpp`'s `sysclib_memset`) returned `0`
  instead of the destination pointer — unlike its own sibling
  `sysclib_memcpy` a few lines above, which correctly returns `dst`.
  GCC's optimization silently turned every `mrb_calloc` call on this
  target into one that returns PPSSPP's wrong `0`, no matter how the
  underlying allocation actually went. `sysclib_memmove` had the
  identical bug (also returning `0` instead of `dst`, where real
  `memmove()` returns its destination too) — not yet observed to be hit
  on this boot path, but fixed alongside `memset` since it is the exact
  same class of gap.

  Fixed by adding `destAddr`/`dst` as the returned value in both
  functions, matching their sibling `sysclib_memcpy`/`sysclib_strcat`
  and the real C `memset()`/`memmove()` contract —
  `nix/patches/ppsspp-sysclib-memset-memmove-return-value.patch`. Not
  upstreamed to `hrydgard/ppsspp` yet, but — like bugs 4 and 8 before it
  — a strong candidate: nothing about this gap is project-specific, and
  any guest code compiled with a GCC that performs this same idiom
  optimization (a common, standard one) would silently get a wrong
  `memset`/`memmove` return value under PPSSPP.

  **Verified: this is the fix that gets the EBOOT booting to
  completion.** Rebuilding PPSSPP with this patch and re-running the
  identical EBOOT under `ppsspp-headless` in normal JIT mode (not `-i`,
  not `MRB_GC_STRESS`) produces, in order: `RPG2K_PSP_BOOT`,
  `RPG2K_PSP_MRUBY_OPEN ok`, `RPG2K_PSP_GAME_START none not_found` (no
  project at `kGameDir` in this smoke-test environment, the expected
  idle path), then a continuous `RPG2K_PSP_BRINGUP` heartbeat every 200
  frames — running cleanly for over 850,000 frames with **zero** bad
  memory accesses, assertions, or errors of any kind, stopped only by
  the test harness's own 15-second timeout. This is the first time
  since this whole P1 investigation began that the EBOOT has booted all
  the way to the idle heartbeat loop under PPSSPP-headless.

  Whether real hardware shares bug 9 is unknown but irrelevant either
  way: real firmware's own `memset`/`memmove` correctly return their
  destination pointer (this was purely an emulator-side gap), so real
  hardware was never going to hit this. With bug 9 fixed, the P1 device
  numbers this section has been chasing since its very first line are
  finally reachable on the emulator — first captured
  `RPG2K_PSP_BRINGUP` line, idle path, `psp-smoke`'s environment (no
  project at `kGameDir`):

  ```
  RPG2K_PSP_BRINGUP frame=0 free=782336 maxfree=524288 lvgl_used=2184
  lvgl_max=2756 stack_free=257872 stack_used_max=4272
  ```

  `free`/`maxfree` (`sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize`)
  and `lvgl_used`/`lvgl_max` hold rock-steady across every subsequent
  heartbeat with no game driving any allocation — expected for the idle
  path, and itself a useful device-side confirmation that the idle HAL
  (LVGL + the two status labels, no mruby object churn) has no leak.
  `stack_used_max` (4272 of the 256 KB `PSP_MAIN_THREAD_STACK_SIZE_KB`
  budget) reflects only `mrb_open()`'s own init recursion on this idle
  path — the *real* game-driving depth (P5) remains unmeasured until a
  project is deployed to `kGameDir`, on real hardware or an emulator
  with a Memory Stick image.

  With the nine-bug idle-path trail closed, this EBOOT was tested for
  the first time against a real project — `data/Nepheshel206beta`, this
  repo's own test fixture, copied to `kGameDir` — rather than the empty
  `kGameDir` `psp-smoke` always exercises. This immediately found a
  **tenth bug, partially fixed**: `RPG2k#initialize`
  (`mruby-rpg2k/mrblib/main.rb`) calls `native_test_play?`, which
  references the `TEST_PLAY` mruby constant directly (rescuing
  `NameError` if undefined) — every other target's entry point defines
  it (`src/main.cxx`), the PSP build never did. Fixed by setting it to
  `false` in `app/psp/main.cxx`, matching `GAME_DIR`/`RTP_DIR`'s
  existing pattern.

  That fix alone is **not sufficient**: constructing `RPG2k` with a real
  project still crashes shortly after, in a genuinely different way — a
  `mrb_assert()` inside mruby's bytecode interpreter (`mrb_vm_exec`,
  `3rd/mruby/src/vm.c`), reached only after several real method calls
  already execute correctly (including at least one full `OP_ENTER`
  argument-binding pass). An extensive trace pass (temporary
  instrumentation across `mrb_funcall_with_block`, `mrb_vm_run`,
  `mrb_vm_exec`'s entry sequence, and `OP_ENTER`'s own handling, none
  kept) ruled out, with direct evidence: `CI_PROC_SET`'s
  `!MRB_PROC_ALIAS_P` assert (the proc is real, non-null, not an alias);
  `MRB_TRY`'s `setjmp` (succeeds normally — `MRB_USE_CXX_EXCEPTION` is
  not defined for this build, so this is the plain `setjmp`/`longjmp`
  path, not C++ exceptions); the computed-goto dispatch table being out
  of bounds (the decoded opcode, `OP_ENTER` = 57, is well within the
  119-entry table, and no `__cxa_guard_acquire` call exists anywhere in
  the compiled `vm.c` object despite it being compiled as C++,
  confirmed via disassembly); and — tested directly, not just
  theorized — the `TEST_PLAY` fix above being sufficient on its own (it
  is not; the crash persists with it applied). The exact failing
  `mrb_assert()` was not pinned to one of the ~25 candidate call sites
  within `mrb_vm_exec`'s many opcode handlers before this pass's time
  budget ran out; a per-opcode trace (needed to see the last few
  instructions executed before the crash) was attempted but proved too
  slow to reach the crash point before the test harness's own timeout,
  since each traced instruction costs a real syscall.

  This is a real, separate, not-yet-fixed bug — the first ever found
  that specifically requires driving this EBOOT with actual game data
  rather than the idle path, since nothing before this pass ever tested
  that. Not part of the original nine-bug boot-blocker count above,
  which is unaffected and remains fully closed for the idle path
  `psp-smoke` verifies.

  **Bug 10 — fixed.** A local, non-Docker/non-Nix reproduction of this
  investigation's build pipeline (the pspdev toolchain and a patched
  PPSSPP built from source directly on the host, since this session's
  environment could not pull either as container images) reproduced the
  crash exactly (`strlen(0000011e)`) against the real
  `data/Nepheshel206beta` fixture, then pinned the failing `mrb_assert()`
  precisely with temporary ring-buffer instrumentation in
  `3rd/mruby/src/vm.c` (all reverted; none of it is in the tree — get a
  fresh copy from this ADR's own git history if the technique is needed
  again) reading directly from the PPSSPP host side, the same technique
  the rest of this section describes:

  - The last opcode executed before the crash is always `Class#new`'s own
    embedded bytecode (`3rd/mruby/src/class.c`'s `new_iseq`) dispatching
    `:initialize` via `OP_SSENDB` with `c=255` (`CALL_MAXARGS`) — this
    holds for every `SomeClass.new(...)` call in the program, not just
    the crashing one, so on its own this only reconfirms where earlier
    passes already got to.
  - Both `RARRAY_LEN`-on-a-non-Array theories floated earlier this
    section (`check_argument_count`'s read of `ci->stack[1]`, and the
    structurally identical unguarded read in `OP_ENTER` at `argc == 15`)
    are **refuted with direct evidence**: at the crashing call,
    `ci->stack[1]` genuinely is a real `Array` (`mrb_type` reports
    `MRB_TT_ARRAY`, `mrb_array_p` is true), with length 0, and the
    resolved `initialize`'s arity (`min=0, max=1`) accepts that — so
    `check_argument_count` returns normally and never raises.
  - The crash is instead inside the resolved method itself: capturing
    `MRB_METHOD_FUNC(m)` right before the call and symbolizing it with
    `psp-addr2line` (reliable for regular compiled code, as noted below)
    identifies it as `(anonymous namespace)::spr_init` —
    `RGSS::Sprite#initialize` (`mruby-rgss/src/lib.cxx:3204`) — called on
    a receiver of class `RGSS::Sprite`. `spr_init` calls `get_display()`
    (`mruby-rgss/src/lib.cxx`), which does
    `mrb_assert(mrb_cptr_p(v))` on the `RGSS::_display` constant. This
    build defines `MRB_DEBUG` (confirmed in the `psp` cross-build's own
    compile flags), so `mrb_assert` compiles to a real C `assert()` —
    and `RGSS::_display` was never set, so `mrb_cptr_p(v)` is false and
    the assert fires. That assert's own abort path is exactly what the
    rest of this section's `strlen(0x11e)` symptom traces back to
    (pspsdk's `__assert_func` → `_exit` → `__libcglue_deinit` calling
    `strlen` on a boxed mruby value as a side effect of tearing down).
  - Root cause: `RGSS::_display` is wired by calling
    `rgss_set_display(M, display)` right after `mrb_open()` succeeds —
    every other target's entry point does this
    (`src/main.cxx:1252`, matching the desktop/Emscripten/Wio builds),
    but `app/psp/main.cxx` never did. It called `psp_display_create(...)`
    for its side effect (standing up the LVGL display) and discarded the
    return value, so nothing downstream ever learned the display existed.
    The bug reproduces the moment any RGSS call reaches `get_display()`
    for the first time; a `Sprite` happens to be the first such call
    while constructing this fixture's initial scene, but any RGSS class
    touching the display first would trip the same assert.
  - Fix: `app/psp/main.cxx` now keeps `psp_display_create`'s return value
    (`lv_display_t* const display`) and calls `rgss_set_display(M,
    display)` immediately after confirming `mrb_open()` succeeded, before
    setting `GAME_DIR`/`RTP_DIR`/`TEST_PLAY` — the same position
    `src/main.cxx` uses.
  - Verified against the real fixture: `RPG2K_PSP_GAME_START RPG2k ok`
    now prints (it never did before this fix — the process crashed
    during `RPG2k.new` before reaching that line), and the crash's own
    `strlen(0000011e)` line no longer appears anywhere near game
    construction. (It still appears once, right at the test harness's
    own `--timeout` cutoff, in *both* the game-data run and the plain
    idle-path `psp-smoke` run with no project at all — i.e. it is a
    generic PPSSPP-headless forced-shutdown artifact when a game never
    calls `sceKernelExitGame` on its own, unrelated to this bug; the
    existing `psp-smoke` job already tolerates this class of flakiness
    by staying non-blocking.)
  - **New, separate finding — resolved (bug 11).** With bug 10 fixed, the
    frame loop's very first `main_loop` call (`app/psp/main.cxx`) still
    crashed before the first `RPG2K_PSP_BRINGUP` heartbeat, during
    `Scene::Title#initialize` (`mruby-rpg2k/mrblib/scene/title.rb`) — **not
    a stall**: reproducing with `--timeout=20` and `--timeout=90` produced
    byte-identical logs (same line count, same final syscalls), so the
    process exited on its own well inside either window; nothing here was
    waiting on the harness to kill it.
    - **Confirmed mechanism**, via a `WalkCurrentStack`/`FormatStackTrace`
      diagnostic patched into PPSSPP's `sceKernelCreateSema` HLE handler
      (same technique as bug 10's own diagnostics; reproduced twice, on
      two different builds, with identical results both times): the crash
      is a genuine, uncaught **C++ exception**. The first `sceKernelCreateSema`
      call after `GAME_START ok` (named `pthread_sem7` by pspdev's
      `libpthreadglue/osal.c`, a plain incrementing counter with no
      significance beyond "the seventh pthread primitive created in this
      process") is the pspsdk pthread glue's own lazy TLS setup, entered
      for the first time from libgcc's C++ personality routine:
      `pte_osSemaphoreCreate <- pthread_mutex_lock <- pthread_setspecific
      <- __cxa_get_globals <- __cxa_throw`. Some code throws a real C++
      exception (`__cxa_throw`) for the first time in the process's life
      at this point. That throw cannot safely unwind past mruby's own
      `vm.c` dispatch loop (compiled as C++, see Finding 3/`OP_ENTER`
      discussion above, but without exception-table coverage for its own
      `NEXT`/`JUMP` dispatch macros — a `setjmp`-based loop, not a
      `try`/`catch` one), so the unwind fails inside libgcc's
      `_Unwind_RaiseException_Phase2`, which calls `abort()`. pspsdk's
      `_kill()` (`glue.c`, `abort()`'s `SIGABRT` handler) implements "kill
      the process" as `sceKernelDeleteThread` on its *own* current thread,
      which the PSP kernel correctly refuses
      (`SCE_KERNEL_ERROR_NOT_DORMANT`) — and that refused delete is what
      cascades into the same `sysclib_strlen(0x11e)` symptom bug 10's own
      diagnostics keyed off of, confirming this is a different bug wearing
      the same visible symptom, not a regression of bug 10 itself.
      **Correction to an earlier assumption in this same investigation:**
      `MRB_THROW` on this build is **not** a plain `longjmp` as first
      stated below (and as an earlier, unverified pass through this
      codebase assumed) — disassembling `exc_throw`'s compiled body
      (`psp-objdump`) shows its `mrb->jmp`-set branch genuinely calls
      `__cxa_allocate_exception` then `__cxa_throw`, wrapping the
      `mrb_jmpbuf*` itself as the thrown object (matching
      `mruby/throw.h`'s `#define MRB_THROW(buf) throw(buf)` — this build
      apparently does get that branch, whatever `MRB_USE_CXX_EXCEPTION`
      reads as here). That in turn means C++ exceptions are mruby's
      *normal*, everyday `raise`/`rescue` mechanism on this build, not a
      rare path in principle — though it later turned out (see "Root
      cause" below) that this crash is in fact the *first* one this
      process's whole life, which is exactly what "unwind fails" turned
      out to mean here: not a property of this specific exception's class
      or stack depth, but of it being the first ever, full stop.
    - **Ruled out with direct evidence**, not speculation:
      - **Not simple arena exhaustion.** A `g_mrb_free` free-list walk
        (the same technique bug 10 used) at the exact `pthread_sem7`
        moment showed **~3.8 MB free of the 8 MB arena**, with a 3.57 MB
        contiguous block — nowhere near exhausted.
      - **Not `Audio.bgm_play` specifically.** The title BGM lookup
        (`mruby-rgss/mrblib/lib.rb`'s `resolve`/`play_packed`, searching
        every extension in `MUSIC_DIRS` then falling back to
        `RGSS.asset_archive`, which is `nil` on this bring-up build) runs
        immediately before the crash and looks like an obvious suspect,
        but bypassing the call entirely (a scratch edit returning early
        from `play_title_bgm` before it) did **not** fix anything — the
        crash just moved to occur after a *different* file-search loop
        (the Continue-availability save-slot scan) instead, at the same
        `pthread_sem7`-then-abort pattern. This means the trigger is not
        audio-specific; whatever throws is reachable from more than one
        code path, or the two searches are coincidental neighbors of
        something else entirely.
      - **Not `RGSS.warn_once`'s `$stderr.puts`.** Also stubbed out as a
        scratch test (mruby-io's `IO#puts` bottoms out in a plain
        `write(2, ...)`, the same primitive `psp_write` already uses
        successfully throughout this whole bring-up); crash persisted
        unchanged.
      - **Not mruby's own OOM-fallback abort path — checked twice, two
        different ways, both negative.** The stack trace's `__cxa_throw`
        frame is consistently attributed by `psp-addr2line`/`WalkCurrentStack`
        to `mrb_core_init_abort` (`3rd/mruby/src/error.c`) — the function
        `mrb_raise_nomemory` falls back to when `mrb->nomem_err` is
        unexpectedly unset. Two independent checks both say this
        attribution is spurious, not real:
        1. A call counter patched directly into `mrb_raise_nomemory`
           itself (`mrb_core_init_abort`'s *only* call site anywhere in
           `3rd/mruby/`, confirmed by grepping the whole tree) — logging
           its caller (`__builtin_return_address(0)`), `mrb->nomem_err`,
           and separate counts for the normal-raise and fatal-fallback
           branches — came back **all zero** after a full crashing run,
           on a build independently re-verified as freshly compiled (not
           the stale-object-file false negative an earlier pass in this
           same session produced and had to correct: that first attempt's
           `build-psp/rpg2k_psp` still disassembled to the *pre*-edit
           `mrb_core_init_abort` despite the source having been changed,
           because the mruby submodule's `git checkout` between builds
           didn't reliably invalidate `rake`'s own incremental cache —
           `rm -rf build-psp/mruby` before rebuilding is what actually
           forces a clean recompile, worth remembering for next time).
           `mrb_raise_nomemory` was, for real this time, never called at
           all.
        2. `__cxa_throw`'s own prologue (`psp-objdump`: `addiu sp,sp,-24;
           sw ra,20(sp)`) saves its real caller at a fixed, known stack
           offset; reading that address directly (bypassing the stack
           walker's own next-frame guess entirely) still landed on
           `mrb_core_init_abort`'s exact entry address, byte-for-byte, on
           two separately-built binaries with two different absolute
           addresses — which looked like unusually strong corroboration
           until a plain byte search of the linked ELF for that exact
           4-byte little-endian address turned up a match inside
           `.eh_frame` (the DWARF unwind-table section, part of what
           `__cxa_throw`'s own `_Unwind_RaiseException_Phase2` reads while
           trying and failing to find a handler). The far more mundane
           explanation: `mrb_core_init_abort`'s address is referenced by
           the unwind metadata itself (it's the nearest function boundary
           to something in an FDE/LSDA table, not a call site), and some
           of that metadata is legitimately sitting on the stack as scratch
           data during the failed unwind — landing exactly on the memory
           address a naive "read the return-address slot" probe checks,
           by coincidence of stack layout, not because anything called
           through it. Both routes to the same wrong answer share one
           root cause, which is worth stating plainly for whoever
           continues: **at this optimization level, a bare address found
           on the stack — however it was obtained — is not evidence of a
           call unless something else independently confirms the callee
           actually ran.** Check 1 is that independent confirmation here,
           and it says no.
    - **The actual `throw` site, found.** The naive techniques that worked
      for bug 10 (reading a return address off the stack, `psp-addr2line`)
      kept producing confident-looking wrong answers here — three separate
      attempts, all eventually traced to `.eh_frame` (the DWARF unwind-table
      section) data sitting on the stack at the exact address each read
      targeted, a coincidence of this specific call site's optimized code
      layout rather than a real return address. What broke the pattern:
      temporarily forcing `-O0` for the whole `psp` mruby cross-build
      (`build_config.rb`, reverted after) to remove tail-call/sibling-call
      elimination and identical-code folding as confounds, *and* switching
      technique entirely — instead of reading raw stack memory after the
      fact, `__builtin_return_address(0)` (a compiler builtin with
      ISA-guaranteed-correct semantics, immune to every failure mode above)
      captured directly inside `3rd/mruby/src/error.c`'s `mrb_exc_raise`
      (the one choke point every `raise` passes through) into a small ring
      buffer. The ring held exactly **one entry** for the whole run — this
      is the *first exception the process ever raises* — of class
      `NameError`. The same technique one level up (inside `mrb_name_error`
      itself) captured the missing symbol directly: `RPG2K_NEW_GAME`.
    - **Root cause.** `Scene::Title#new_game_flag?`/`#auto_continue?`
      (`mruby-rpg2k/mrblib/scene/title.rb`) and `RPG2k#headless_battle_troop`/
      `#preview_map_id` (`mruby-rpg2k/mrblib/main.rb`) each reference one of
      `RPG2K_NEW_GAME`/`RPG2K_CONTINUE`/`RPG2K_PREVIEW_MAP`/
      `RPG2K_BATTLE_TROOP` directly, every reference already wrapped in its
      own `rescue StandardError` — the same deliberate, working pattern
      `TEST_PLAY` uses (see bug 10's fix above), because these four are
      genuinely optional: `src/main.cxx` (the desktop/CLI target) is the
      *only* target that ever defines them, from its own `--rpg2k_new_game`
      etc. flags, and every non-CLI target is expected to leave them unset
      and let the `rescue` catch it. `app/psp/main.cxx` never defined any of
      the four (only `TEST_PLAY`), so the very first one `Scene::Title`
      touches raises — and that `rescue` clause, though correct, never
      catches it: this is the *first* real C++ exception the process has
      ever thrown, and on this toolchain the one-time pthread/TLS lazy
      bootstrap `__cxa_throw` needs the first time it runs
      (`pthread_setspecific` inside `__cxa_get_globals`, allocating its
      first internal semaphore — the `pthread_sem7`/`sceKernelCreateSema`
      call this whole investigation kept keying diagnostics off of) does not
      complete correctly, so the exception never reaches the `rescue` at
      all — it aborts via libgcc's `_Unwind_RaiseException_Phase2` failure
      path instead, the same `sysclib_strlen(0x11e)` symptom bug 10 traced.
    - **Fix.** `app/psp/main.cxx` now defines all four constants right after
      `TEST_PLAY`, matching `src/main.cxx`'s own defaults for an unset flag
      (`RPG2K_NEW_GAME`/`RPG2K_CONTINUE` `false`, `RPG2K_PREVIEW_MAP`/
      `RPG2K_BATTLE_TROOP` `0`) — sidestepping the fragile first-throw path
      entirely rather than trying to fix it (a toolchain-level fix, if one
      is even needed elsewhere, is a separate, larger undertaking; see
      below).
    - **Verified against the real fixture:** `RPG2K_PSP_GAME_START RPG2k ok`
      still prints, and — for the first time in this entire investigation —
      `RPG2K_PSP_BRINGUP` heartbeats now flow continuously (`frame=0`, `200`,
      `400`, … up to `176800` over the run), with zero occurrences of
      `strlen(0000011e)` anywhere in the log. `RPG_RT.lmt` (the map tree)
      is now read too, confirming the boot gets well past `Scene::Title`.
    - **Residual, deliberately out of scope here:** *why* the first-ever
      `__cxa_throw` on this toolchain fails to unwind is still not
      understood, only worked around. Nothing else in this bring-up's own
      code currently depends on a `rescue` catching a truly first-of-its-
      kind exception (every other `rescue` site either isn't first or isn't
      reached before something else already threw once), but that is
      incidental, not guaranteed — a future change that adds a new,
      genuinely-could-be-first raise on some other path could hit the same
      failure mode. If it recurs, this section's diagnostic trail (ring
      buffer at `mrb_exc_raise`, `__builtin_return_address(0)`, `-O0` to
      defeat ICF/tail-calls) is the fastest way back to a real answer;
      "prime" the exception machinery deliberately early in `main()` (throw
      and catch something trivial before any real game code runs) is the
      most promising untried fix if a case ever needs it for real, since it
      would force the same one-time pthread/TLS bootstrap to happen in a
      controlled spot instead of wherever the first real exception happens
      to land.
- **P1a — done.** Stripped `-g` from `mrbc`'s compile options in the `psp`
  `MRuby::CrossBuild` block (`build_config.rb`), closing Finding 5's one real
  gap; confirmed `-O0` needed no fix (already stripped) and `-g3` needed none
  either (file size only). This is Decision work that shipped as code rather
  than staying a P-item — see Consequences.
- **P2 — decided for this target: mruby gets its own bounded arena.** Sharing
  LVGL's pool the way desktop does is not viable on the PSP: the builtin TLSF
  pool only aligns to 4 bytes on a 32-bit build (`lv_mem_core_builtin.c`'s
  `ALIGN_MASK`), which breaks mruby's word boxing — the same reason the
  Emscripten build opts out — and plain `malloc` lets the interpreter grow
  unbounded until it collides with the decoded-bitmap heap. `app/psp/main.cxx`
  now overrides `mrb_basic_alloc_func` (the mruby 4.0 global allocator hook)
  with a fixed 8 MB first-fit arena (16-byte aligned, with splitting and
  coalescing; the same "linker never pulls the default from libmruby.a"
  pattern desktop uses). When the arena is exhausted the allocator returns
  NULL and mruby raises a catchable `NoMemoryError` instead of corrupting RAM.
  `app/psp/lv_conf.h`'s comment now states this accurately (the pool covers
  LVGL only) instead of describing the un-taken shared-pool option. The 8 MB
  figure is a generous placeholder to be validated against a real game
  on-device, exactly as the BRINGUP heartbeat (P1) measures.
- **P2a — `LV_MEM_SIZE` cut from 4 MB to 256 KB.** Once P2 moved mruby onto
  its own arena, checked what is actually left for LVGL's pool to cover:
  decoded bitmaps bypass it (Finding 3), the LVGL partial-render draw buffers
  are plain `std::vector` (`psp.cxx`'s `g_buf1`/`g_buf2`, not `lv_malloc`'d
  either), and the real game never reaches LVGL's own font/text system at
  all — every game screen draws through the RGSS `Bitmap`'s shinonome
  blitter; only the idle bring-up screen's two `lv_label`s ever touch it. So
  the pool's only job is `lv_obj_t`/style/internal bookkeeping for the
  canvas/image/label widgets this port actually uses (already trimmed to
  those three by P6 below) — plausibly tens of KB even for a busy screen, not
  megabytes. 4 MB was never validated against anything; 256 KB is a
  comfortable multiple of that estimate, still awaiting the same on-device
  BRINGUP validation P2's 8 MB arena figure does.

  This one has a sharper failure mode than the arena, though: LVGL's default
  `LV_ASSERT_HANDLER` (fired by `LV_USE_ASSERT_MALLOC`, on for this target)
  is an unconditional `while(1);` — pool exhaustion would have looked like
  any other silent hang, which is exactly the class of bug the rest of this
  ADR's Consequences spent real effort chasing. `app/psp/lv_conf.h` now
  points `LV_ASSERT_HANDLER` at `psp_lvgl_assert_halt`
  (`mruby-rgss/src/psp.cxx`), which writes a libc-free `RPG2K_PSP_LVGL_ASSERT`
  marker via `sceIoWrite` before halting — the same `StrBuf`/`psp_write`
  reasoning `main.cxx` already uses, since `sysclib_snprintf` is not to be
  trusted here either. Verified the shrunk pool builds clean and the idle-HAL
  screen (title + status label) does not trip that marker under
  PPSSPP-headless; validating it against a real game's widget count still
  needs the same on-device run P1/P2 do.
- **P6 — drawn from Finding 3's "third pool" and the EBOOT's own size,
  landed as four smaller reductions:**
  - The uni-algo modules nothing in this project calls are switched off, so
    their Unicode tables are never compiled in (`cmake/uni-algo-trim.cmake`,
    mirrored into the mruby cross-builds by `build_config.rb`). The repo uses
    exactly three uni-algo features — UTF conversion, the UTF-8 decoding view,
    and NFD normalisation — none of which need the case/collation, code-point
    property, script, grapheme/word segmentation or compatibility-normalisation
    tables. Measured on the EBOOT with `nm --size-sort`: the `una::detail::*`
    tables fall from 663 KB to 145 KB, `.rodata` from 2,238,894 B to
    1,723,798 B, and the loaded R/E segment by 517,920 B — **~506 KB of live
    RAM**, since the loader maps every PT_LOAD segment into the console's
    ~24 MB at launch. Desktop and wasm shrink by the same tables for free.
    This is also ADR 0007's P2 lever for the Wio Terminal (whose 512 KB of
    internal flash cannot hold the full set at all), where it takes effect
    when that port links `libmruby.a`.
  - The LVGL partial-render draw buffers are sized to the *logical* canvas at
    display-create time (`mruby-rgss/src/psp.cxx`), capped at the old
    panel-width 64 KB per buffer: RPG2k's 320×240 canvas needs ~38 KB per
    buffer (~76 KB total vs the old fixed 128 KB), while an XP/VX canvas
    (wider than the panel) keeps fewer rows per flush instead of growing.
  - The EBOOT no longer links LVGL's examples/demos (they are PUBLIC-linked
    into `liblvgl.a` by default) or any widget beyond the RGSS layer's actual
    set (canvas/image/label) — the default theme, which `lv_display_create`
    auto-installs and whose styles reference every widget, is disabled so the
    unused widget object files are no longer pulled into the link. On the PSP
    every byte of the EBOOT is loaded into RAM at launch, so this is live
    memory, not just flash.
  - The `psp` mruby cross-build (and the `wio` one) now sets mruby's
    micro-controller tuning knobs `MRB_HEAP_PAGE_SIZE=256` and
    `KHASH_INITIAL_SIZE=16` (the `MRB_CONSTRAINED_BASELINE_PROFILE` set minus
    `MRB_NO_METHOD_CACHE`, which would cost dispatch speed), shrinking GC heap
    page granularity and the initial khash bucket counts with no behaviour
    change.
- **P3 — done (the tool; the deployment step itself is still per-release).**
  `scripts/rgssad_unpack.rb` unpacks a `Game.rgssad`/`.rgss2a`/`.rgss3a`
  (desktop-side, reusing the existing `RPGXP::RGSSAD` reader rather than
  reimplementing the format) into a loose file tree in place beside it,
  exactly where the loose-file-first loaders already look. Verified against
  real Marshal-encoded `.rxdata` (the `OpenGame.exe` XP test-bed
  `scripts/download-opengame-xp.bash` already fetches for CI): packed both as
  v1 and v3 archives, unpacked, diffed byte-for-byte against the originals —
  exact match both ways. What's still a per-release step, not something this
  tool can do for you: excluding the packed archive from a given PSP
  deployment so `open_archive` never reads it (see Finding 2's catch) — the
  unpacker never touches or deletes the archive itself. A streaming `RGSSAD`
  reader remains the fallback if Memory Stick space, not RAM, turns out to be
  the constraint for a release that can't afford the doubled storage.
- **P4 — corrected; not an LVGL-cache problem.** There is no LVGL image
  cache to bound for RGSS bitmaps (Finding 3) — they live in the plain C
  runtime heap via `Bitmap::buffer`, a third pool `LV_MEM_SIZE` never
  touches. Nothing to implement here that isn't already covered: once the
  interpreter is linked and real bitmaps are loaded, P1's heartbeat already
  surfaces this pool's consumption as the gap between
  `sceKernelTotalFreeMemSize` and `lv_mem_monitor`'s LVGL-only figures. What
  remains is confirming decoded-bitmap sizes for the target games'
  resolutions actually fit in what's left of the ~24 MB after `LV_MEM_SIZE`
  and the stack/statics — a measurement to take once P1's device numbers
  exist for a real game, not a code change.
- **P5 — done (the sizing and the measurement; the number itself still wants a
  real game).** `app/psp/main.cxx` now declares
  `PSP_MAIN_THREAD_STACK_SIZE_KB(256)` instead of inheriting pspsdk's implicit
  default, and the `RPG2K_PSP_BRINGUP` heartbeat carries two more fields,
  `stack_free` and `stack_used_max`. `sceKernelGetThreadStackFreeSize` reports
  how much of the stack is still the 0xFF fill pspsdk left at thread creation;
  because a down-growing stack never restores those bytes once a frame has
  written over them, *any* sample is already the high-water mark of how deep
  the interpreter has recursed, and `stack_used_max` keeps the running maximum
  so an error return cannot walk the reported figure backwards. 256 KB is the
  size that already runs the real RPG2k scene tree — what changes is that the
  log now shows how much of it a title actually reaches, so a deeper-recursing
  game is caught by the numbers rather than by a crash. Like the arena's 8 MB
  (P2), turning 256 KB from "runs today" into a justified figure needs a real
  game at `kGameDir`, which CI's `psp-smoke` does not have.

## Consequences

- Unlike ADR 0007's discipline of agreeing every number before any code
  lands, this revision ships small, self-contained changes alongside the ADR
  update: P1a (stripping mrbc's `-g` for the `psp` cross-build), half of P1
  (the bring-up EBOOT's heartbeat now reports real device memory numbers),
  the tool half of P3 (`scripts/rgssad_unpack.rb`), the P2 allocator
  split plus P2a's LVGL pool cut (4 MB to 256 KB, with a marker-writing
  assert handler replacing LVGL's silent-halt default) plus P6's reductions
  (draw buffers sized to the canvas, the LVGL widget/theme/example trim, the
  mruby embedded tuning knobs, and the uni-algo table trim), and P5's
  explicit main-thread stack size plus its heartbeat fields. The three sizing
  numbers that still depend on a real database and map actually being loaded
  are the mruby arena's 8 MB, LVGL's 256 KB, and the stack's 256 KB, all
  three of which the heartbeat is now in place to validate.
- ADR 0010's "the full gem set should fit" is narrowed: it holds for gem
  *code* size, but says nothing about per-title asset memory, which Finding 2
  shows can exceed the entire 24 MB budget for an RGSSAD-packed game even
  though the Wio Terminal's port needed the same warning at a much smaller
  scale.
- **Risk register:** P2 is now decided (a bounded 8 MB mruby arena, see the
  Decision) rather than soft-blocking, but its *size* is still a placeholder
  awaiting on-device numbers — the BRINGUP heartbeat measures it, so that is a
  measurement follow-up, not an architectural one. P3 (RGSSAD whole-archive
  loads) is hard-blocking for any future XP/VX PSP target; the
  tool to close it is done, but running it and excluding the packed archive
  is still a manual step per release, not something CI or the build enforces
  — that's the remaining risk, not the unpack logic itself. P4 is a
  lower-risk follow-up once a title actually renders; P5 is now measured
  rather than guessed, leaving only the same "needs a real game" caveat P2's
  arena size has.
- Follow-up: once P1's real numbers exist, replace this ADR's estimates with
  measured figures (a memory budget table, as ADR 0007 has for the Wio
  Terminal) — either as an amendment here or a superseding ADR.

## Addendum: `psp-smoke` promoted to a required check

The bug-11 finding above (the boxed-`mrb_value`/`get_display()` assert) noted
in passing that the forced-shutdown `strlen` crash PPSSPP-headless logs when
`--timeout` kills a game that never called `sceKernelExitGame` is generic —
it appears in *both* the game-data run and the plain idle-path `psp-smoke`
run with no project at `kGameDir` at all — and said the existing job "already
tolerates this class of flakiness by staying non-blocking." That framed it as
an open risk. It is not one in practice: the check
`app/psp/README.md`/`.github/workflows/build.yml`'s `psp-smoke` job runs is
`grep -qE 'RPG2K_PSP_(BOOT|BRINGUP)' headless.log` against a log the emulator
invocation writes with `|| true` (exit code ignored) — and `RPG2K_PSP_BOOT` is
the very first thing the EBOOT ever writes, before any init, while the
timeout-triggered crash by construction happens only at the *end* of the
15-second run, after both markers are already in the log. The crash is real
log noise, but it cannot make this grep fail. Checked directly: the ten most
recent `master` CI runs at the time of this addendum all show `psp-smoke`
green (`success`), with no exceptions, matching that reasoning. The job's
`continue-on-error: true` has accordingly been removed — it is now a required
check alongside `psp`, and `app/psp/README.md`'s own description of the job
has been updated to match.
