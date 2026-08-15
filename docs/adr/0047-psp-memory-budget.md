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
  emulator with a Memory Stick image.
- **P1a — done.** Stripped `-g` from `mrbc`'s compile options in the `psp`
  `MRuby::CrossBuild` block (`build_config.rb`), closing Finding 5's one real
  gap; confirmed `-O0` needed no fix (already stripped) and `-g3` needed none
  either (file size only). This is Decision work that shipped as code rather
  than staying a P-item — see Consequences.
- **P2 — decide the allocator split explicitly.** Either accept the default
  (mruby shares `LV_MEM_SIZE` with LVGL, matching desktop) and size that one
  pool generously enough for both from the P1 measurements, or add a PSP
  exception next to Emscripten's in `src/main.cxx`/the PSP entry point so
  mruby gets its own bounded arena. Whichever is chosen, fix
  `app/psp/lv_conf.h`'s comment to state it accurately instead of describing
  the un-taken option.
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
- **P5 — size and verify the main-thread stack** against measured mruby
  init/interpreter recursion depth, with a high-water-mark check rather than
  a guessed constant.

## Consequences

- Unlike ADR 0007's discipline of agreeing every number before any code
  lands, this revision ships small, self-contained changes alongside the ADR
  update: P1a (stripping mrbc's `-g` for the `psp` cross-build), half of P1
  (the bring-up EBOOT's heartbeat now reports real device memory numbers),
  and the tool half of P3 (`scripts/rgssad_unpack.rb`). None of these is a
  pool-sizing or allocator decision — those still depend on numbers only the
  interpreter-linking slice can produce (a real database and map actually
  loaded) — so the rest of the Decision items remain design record only.
- ADR 0010's "the full gem set should fit" is narrowed: it holds for gem
  *code* size, but says nothing about per-title asset memory, which Finding 2
  shows can exceed the entire 24 MB budget for an RGSSAD-packed game even
  though the Wio Terminal's port needed the same warning at a much smaller
  scale.
- **Risk register:** P2 (allocator split / pool sizing) is soft-blocking the
  interpreter-linking slice — the slice can land without it decided, but
  `LV_MEM_SIZE` will be guessed rather than sized until it is. P3 (RGSSAD
  whole-archive loads) is hard-blocking for any future XP/VX PSP target; the
  tool to close it is done, but running it and excluding the packed archive
  is still a manual step per release, not something CI or the build enforces
  — that's the remaining risk, not the unpack logic itself. P4/P5 are
  lower-risk follow-ups once a title actually renders.
- Follow-up: once P1's real numbers exist, replace this ADR's estimates with
  measured figures (a memory budget table, as ADR 0007 has for the Wio
  Terminal) — either as an amendment here or a superseding ADR.
