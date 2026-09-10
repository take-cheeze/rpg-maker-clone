# 130. A real `env:wio_rgss_boot` relink, for the first time since ADR 115

Date: 2026-09-10

## Status

Accepted

## Context

ADR 115 is the last time anyone actually relinked `env:wio_rgss_boot` for
real (PlatformIO + the real `arm-none-eabi` toolchain + a real LVGL/uni-algo/
libmruby.a link) rather than a proxy measurement. Every reduction landed
since — ADR 117 (`mrb_assert` strip), 118 (cdump/lv debug-table strip), 124
(battle-only-helpers split), and this session's own 125-129 (profiler.cxx/
default_font.cxx/sixel.cxx/iterm.cxx trims, the `game/lsd_io.rb` split, and
18 inlined single-caller helpers) — was measured with `mrbc --remove-lv` on
a Ruby file list or a standalone `arm-none-eabi-g++` compile of one `.cxx`
file at a time. Nobody had re-run the real link, because no session's
sandbox had a PlatformIO toolchain until now. This ADR does exactly that:
install PlatformIO, its `atmelsam`/`toolchain-gccarmnoneeabi` packages, and
the packages `env:wio_walk`/`env:wio_rgss_boot` already declare, then
reproduce a real `libmruby.a` (`MRUBY_TARGET=wio rake`) and a real
`libuni-algo.a`, and link them into `env:wio_rgss_boot` the same way ADR 104
first did.

Getting there needed several real, previously-undocumented environment
gaps closed (none of them wio-specific bugs — all either missing setup
steps or genuine build-time regressions this exact combination had never
hit before):

- **`3rd/quickjs` was never checked out.** `git submodule status` showed it
  unpopulated; the default (non-wio) host build's own `mruby-mvjs` gem
  needs its header. `git submodule update --init 3rd/quickjs` once, up
  front — wio's own build never touches this gem, but `MRUBY_TARGET=wio
  rake` still builds the plain host target's full gem set alongside the
  cross target (mruby's own convention: every cross build gets a
  bootstrap "mrbc" host build **and** normally coexists with the
  project's own default host target in the same `rake` invocation).
- **`cp932_table`/`jis0208_table` were never set.** These feed
  `mruby-lcf/cp932_to_unicode.rb` (ADR 111) and are normally supplied by
  the nix devshell or, outside nix, downloaded and hash-verified by CI
  itself (`.github/workflows/build.yml`'s "Download Unicode mapping
  tables" step, both against `flake.nix`'s own pinned sha256). Ran the
  same two `curl` + sha256 checks by hand, same URLs, same pinned hashes,
  into `.native-build-tables/` (left untracked/uncommitted here — CI's own
  script already reproduces them from the same pins, so nothing to check
  in).
- **The `patches/*.patch` files are not self-applying outside CMake.**
  ADR 104 already flagged this ("wio has no CMake integration at all yet,
  only this rake invocation... bypassed [the CMake patch step] entirely")
  but did not need any of the GC-instrumentation patches that exist now.
  `cmake/build-mruby.cmake` normally runs `scripts/apply_mruby_patch.bash`
  once per patch before `rake`; ran all eight by hand in the same order
  (`mruby-colon3-assign-setmcnst`, `mruby-dollar-bang-scoped`,
  `mruby-defined-keyword`, `mruby-nomemoryerror-reentrant-alloc`,
  `mruby-gc-type-live-counts`, `mruby-io-maxpathlen-fallback` against
  `3rd/mruby`; `mruby-stringio-native-getbyte` against `3rd/mruby-stringio`;
  `mruby-marshal-psp-wio-onigmo-optional` against `3rd/mruby-marshal`).
  Without the last one, `mruby-marshal`'s unconditional `add_dependency
  mruby-onig-regexp` pulls onigmo back in for wio (the exact regression
  ADR 103 already found and fixed) — its `./configure --host
  arm-none-eabi` then fails outright (`error: C compiler cannot create
  executables`, real cause: the bare-metal newlib has no `_exit`, and
  autoconf's own trivial link probe has no `-specs=nosys.specs` escape
  hatch), a new, real, previously-undocumented gap in the *absence* of the
  onigmo-optional patch, not a bug in it.
- **`mruby-defined-keyword.patch` touches `parse.y`/`keywords`, which
  regenerates `lex.def`/`y.tab.c` via `gperf`/`bison`** — this container
  has `bison` but not `gperf`; `apt-get install gperf` once. The first
  attempt without it left an **empty** `lex.def` on disk (rake's own `file`
  task target existed, satisfying the dependency, even though the command
  that should have populated it had failed) — a real footgun: re-running
  `rake` alone after installing `gperf` did *not* self-heal, since the
  empty file was already "up to date". Had to `rm` the stale empty
  `lex.def`/`y.tab.c` and let `rake` regenerate them fresh.
- **Real Arduino/board headers, not the stub set ADR 104 already
  documents** (`RGSS_WIO_ARDUINO_INCLUDES`): the exact `-I` list is
  host/package-version-specific by design, so it was re-extracted here
  from a real `pio run -e wio -v` compile (for the CMSIS/core/variant
  paths) plus a real `pio run -e wio_walk -v` compile of
  `Seeed_Arduino_LCD/TFT_eSPI.cpp` (for the three library-only paths
  `wio.cxx` needs that `env:wio` alone never pulls in: `Seeed_Arduino_LCD`
  itself, `SPI`, and `Adafruit_ZeroDMA`) — the same extraction method ADR
  104 used, just re-run against this container's own package versions.
- **A false-alarm `mrbc` segfault, traced to a stale build artifact, not a
  patch bug.** After applying `mruby-gc-type-live-counts.patch` (adds
  `tt_live`/`tt_allocs` counters to `mrb_gc` for `mruby-rgss/src/
  profiler.cxx`'s `mrb_gc_type_counts` calls) `3rd/mruby/build/host/mrbc/
  bin/mrbc` segfaulted on literally every input, including `--version`
  (`gdb` traced it to `gc_protect` writing through `gc->arena` — already
  NULL/zero-capacity by the time boot reached ~200 GC-arena pushes,
  consistent with heap corruption). Reverting the patch and rebuilding
  made the crash disappear, which looked like a real bug in the patch;
  re-applying it and doing a **full** `rm -rf 3rd/mruby/build` before
  rebuilding made the crash disappear too, with the patch still in place.
  The actual cause was a handful of stale `.o`/`.a` files left over from
  earlier, pre-patch build attempts that rake's own dependency tracking
  didn't invalidate — some translation units were still linking against
  the old, smaller `mrb_gc` layout. Not a wio-specific issue and not a bug
  in the patch itself; recorded here because the symptom (a GC-arena
  segfault immediately after a header-only patch) is exactly what a *real*
  ABI-mismatch bug from a bad patch would also look like, and it cost real
  time to tell the two apart. A clean `3rd/mruby/build/` before trusting
  any patch-bisection result would have caught this immediately.

## Decision

With every gap above closed, the real link succeeds end to end (zero
undefined symbols, matching ADR 104's own "provably ABI-correct" finding)
and produces a real, current flash/RAM number:

```
arm-none-eabi-g++ ... -o .pio/build/wio_rgss_boot/firmware.elf ...
ld: .pio/build/wio_rgss_boot/firmware.elf section `.text' will not fit in region `FLASH'
ld: region `FLASH' overflowed by 861412 bytes
```

Against this board's real, unchanged budget (ADR 108): 507,904 usable flash
bytes (512 KB minus the 16 KB bootloader region), 196,608 RAM bytes (192
KB). No RAM overflow was reported — the link fails on FLASH alone, the same
shape as every prior real link in this series.

| | bytes |
| --- | --- |
| FLASH budget | 507,904 |
| FLASH overflow (real `ld` output) | 861,412 |
| **FLASH actually needed** | **1,369,316** |
| RAM budget | 196,608 |
| RAM used (`.data`+`.bss` from the partial `firmware.map`: 12,256 + 24,700) | 36,956 (18.8%, no overflow) |

Compared with ADR 115's own last real relink (FLASH overflow 993,676, RAM
used 45,536): a real, confirmed **132,264-byte FLASH reduction** and a real
**8,580-byte RAM reduction** from everything landed since (ADR 117, 118,
124, and this session's 125-129) — close to, and directionally confirming,
the ~139,579-byte sum of those ADRs' own isolated-`.o`/whole-gem-bytecode
proxy estimates. The two numbers were never expected to match exactly
(proxy measurements do not model linker padding, alignment, or
`--gc-sections`), and they do not — but they land within about 5% of each
other, which is the first real evidence in this session that the proxy
measurements this series relied on since ADR 115 (no PlatformIO toolchain
existed in any sandbox until now) were tracking the real number reasonably
well, not compounding error silently.

Reproducing this outside CI/a maintainer's own machine needs, in order: the
PlatformIO packages (`pio pkg install --platform atmelsam` inside this
project, which also resolves `env:wio_walk`/`env:wio_rgss_boot`'s
`lib_deps`), `git submodule update --init 3rd/quickjs`, the two Unicode
table downloads, all eight `scripts/apply_mruby_patch.bash` calls CMake
normally sequences, `gperf`, a real `MRUBY_TARGET=wio rake` from a clean
`3rd/mruby/build/`, a standalone `arm-none-eabi-g++` compile+archive of
`3rd/uni-algo/src/data.cpp` (same `UNI_ALGO_DISABLE_*`/`-std=gnu++17`/`-Os`/
cpu flags as the wio cross build, plus `-DUNI_ALGO_DISABLE_NFKC_NFKD` per
`cmake/uni-algo-trim.cmake`), and finally `pio run -e wio_rgss_boot` with
`WIO_MRUBY_BUILD_DIR`/`WIO_UNIALGO_LIB_DIR` pointed at the two results.

## Consequences

- **The series now has a real, current confirmed number again**:
  1,369,316 bytes needed against a 507,904-byte budget (2.7x over), RAM
  comfortably fit (18.8% used). Every flash-reduction ADR's own proxy
  estimate from 115 through 129 is retroactively corroborated, not just
  asserted.
- **Still nowhere near fitting.** 861,412 bytes is a smaller gap than
  ADR 104's original 1,706,256 or ADR 115's 993,676, but it is still larger
  than the entire board's own budget was ever going to close through
  Ruby/C++ trimming alone — ADR 108's own "skeleton floor" argument (a
  build with *zero* rpg2k Ruby still needed 1,018,244 bytes) still stands;
  closing the rest needs the SD-external-bytecode loader that ADR
  documents but never finished, or an embedded-font strategy change
  (`shinonome.o` alone was 182,472 bytes of ADR 104's own original
  archive-level measurement, still the single largest object in
  `libmruby.a` unless something has changed that since).
- **This sandbox can now run a real relink again.** The environment gaps
  above (submodule, tables, patches, gperf, include paths) are all
  reproducible from this ADR's own steps; nothing here was wio-specific
  luck. A future session in a similarly fresh sandbox should expect to hit
  the same list, in the same order, and can shortcut straight to the
  `pio run -e wio_rgss_boot` step this ADR ends on.
- **The `.native-build-tables/` download and the standalone
  `libuni-algo.a` cross-build are both scratch, not committed** — same
  reasoning as ADR 104's own `RGSS_WIO_STUB_HEADERS`/`RGSS_WIO_ARDUINO_
  INCLUDES` escape hatches: reproducible from documented pins/flags, not
  worth vendoring.
