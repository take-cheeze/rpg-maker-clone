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

- **P1 — measure before sizing.** Partially done. Finding 1's ~1.2–1.4 MB and
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
  emulator with a Memory Stick image. **On the emulator side specifically,
  this heartbeat has never yet produced a captured number**, in CI or
  locally, though the reasons have narrowed a lot:
  Eight independent bugs have been found and root-caused on this path so
  far, six of them fixed; boot still does not complete. In the order the
  EBOOT actually hits them:
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
  `mrb_open`'s GC init before hitting an **eighth bug, partially fixed and
  re-characterized**: PPSSPP reports `Bad memory access detected!
  00000014` (or a nearby small address — see below) — a near-null write —
  inside `mrb_gc_init`. A first pass at this root-caused it to "PPSSPP's
  x86-64 JIT mistranslating the guest MIPS code", based on: every
  allocation up to the crash point tracing as valid (a temporary
  instrumentation pass through the fixed arena and vendored
  `mrb_gc_init`/`add_heap`/`init_heap_page`/`shape_root`,
  `3rd/mruby/src/{gc,state,variable}.c`, none kept); the crash log's own
  disassembly of the faulting *host* instruction, `mov [rbx+r9+0x4],
  r10b`, inside the JIT block for `mrb_gc_init` (the compiler had inlined
  `add_heap`'s `init_heap_page` loop into it — `page->objects[i].as.free.tt
  = MRB_TT_FREE`, a small per-object byte-store loop, is the only matching
  source shape); and `ppsspp-headless -i` (forces the plain MIPS
  interpreter, bypassing the JIT entirely) running the identical EBOOT
  784+ allocations further with zero bad-memory-access errors.

  A second pass found a real, separate PPSSPP bug along the way — **fixed**:
  `Common/x64Analyzer.cpp`'s `X86AnalyzeMOV`, which `Core/MemFault.cpp`
  uses to recover from a bad guest access when `bIgnoreBadMemAccess` is
  set (headless mode's default), only recognized the 32/64-bit-register
  MOV opcodes (`0x89`/`0x8B`), not the 8-bit-register forms (`0x88`/`0x8A`)
  the JIT emits for exactly this kind of byte store — hitting one during
  recovery hit `X86AnalyzeMOV`'s own `default:` case and got treated as
  unrecoverable, halting emulation outright instead of being skipped like
  every other access width already is. `nix/patches/
  ppsspp-x64analyzer-8bit-mov.patch` adds both missing opcodes; confirmed
  it eliminates the fatal halt (`Stopping emulation`) under *both* of
  PPSSPP's native JIT backends (the old per-arch `Core/MIPS/x86/Jit.cpp`
  and the newer IR-based `Core/MIPS/x86/X64IRJit.cpp`), converting the
  crash into the same graceful "ignored" recovery every other store width
  already gets.

  Applying that fix does **not** get this EBOOT booting further, though —
  and comparing all four of PPSSPP's CPU-core modes against the identical
  patched EBOOT turned up evidence against the original "JIT
  mistranslation" diagnosis: the byte-for-byte *same* fault address
  sequence (0x18, 0x14, 0x2c, 0x28, ...) reproduces under the old x86 JIT,
  under `JIT_IR` (an independently-implemented native backend), *and*
  under `--ir` (`IR_INTERPRETER`, which shares `JIT_IR`'s MIPS-to-IR
  frontend but does no native code generation at all — it segfaults the
  *host* process outright at the same point, since the IR interpreter has
  no `bIgnoreBadMemAccess`-style recovery path). Two independently-coded
  native backends agreeing byte-for-byte, plus the IR interpreter hitting
  the identical point despite generating no machine code, is hard to
  explain as a backend-specific register-allocation bug; it fits a lot
  better as something shared by every "compile/analyze a block ahead of
  time" execution mode, and *not* shared by the one mode that's genuinely
  different — the plain MIPS interpreter, which single-steps each
  instruction directly against `currentMIPS`'s live state rather than
  translating a block up front. That points at a timing-sensitive
  condition (an interrupt or HLE callback racing unprotected/non-reentrant
  guest state, matching this whole trail's running "memory corruption over
  logic bugs" theme, and echoing bug 4's own interrupt-masking fix) as the
  more likely next lead, over a genuine JIT translation bug — but this
  pass did not chase that down further; it is a real, open question, not
  a new final diagnosis. With the x64Analyzer fix applied, this EBOOT's
  own boot still does not complete: execution proceeds past the fault
  point instead of halting, but the underlying corruption persists, and
  the guest program calls `sceKernelExitGame()` on its own partway through
  `mrb_open` without ever printing `RPG2K_PSP_MRUBY_OPEN` — consistent
  with the corruption leading to wild/divergent control flow rather than
  a successful `mrb_open()`.

  Not upstreamed to `hrydgard/ppsspp` yet. The x64Analyzer fix is worth
  upstreaming on its own regardless of this EBOOT's own outcome — it is a
  genuine gap relative to PPSSPP's own intended `bIgnoreBadMemAccess`
  behavior, useful to any guest code that trips a byte-sized bad access
  under the JIT. `-i` (interpreter mode) is not viable as a shipping
  workaround (far too slow for real gameplay) but remains useful for
  diagnosis.

  Whether real hardware shares bugs 7 or 8 is unknown (bugs 3 and 6 are
  moot on this boot path either way, one because it stopped triggering,
  the other because it's fixed); bug 8's underlying corruption may or may
  not be emulator-specific — unresolved by this pass. The P1 device
  numbers above remain unconfirmed on the emulator and untried on
  hardware.
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
