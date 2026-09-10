# 141. A real linker-map breakdown of docs/adr/0140's 312,105-byte "unclassified" bucket

Date: 2026-09-10

## Status

Accepted (an investigation and a real breakdown — no source change)

## Context

docs/adr/0140 re-measured `wio_rgss_boot`'s real flash overflow (675,960
bytes after its own JPEG-decoder trim) and produced a rough category
breakdown of the full linked binary by grepping `arm-none-eabi-nm`'s symbol
names for known patterns. One bucket was explicitly left unresolved:

> The 312,105-byte "unclassified" category (Arduino framework/TFT_eSPI/
> FreeRTOS/newlib/C++ unwind tables/mruby-rgss's own glue) ... a real
> linker-map-based per-object-file pass (`firmware.map`, already produced by
> every `wio_rgss_boot` link via `-Wl,-Map=...`) could plausibly find more
> real, safe wins the same shape as this ADR's, but needs more time than
> this session had to do with the same rigor.

This session did that pass for real.

## What was done

**A fresh, real link**, independently reproduced in this session's own
worktree (not just reused from elsewhere): submodules initialised
(`git submodule update --init --recursive`), all nine `patches/*.patch`
files applied by hand in `cmake/build-mruby.cmake`'s own order (all nine
applied cleanly, none already applied), the two CP932/JIS0208 Unicode tables
downloaded and hash-verified against `flake.nix`'s own pins, and a real
`arm-none-eabi-g++` 14.2.1 (PlatformIO's own pinned
`toolchain-gccarmnoneeabi@1.140201.0` package, confirmed present) used
throughout. A byte-identical `libmruby.a`/`libuni-algo.a` pair already built
this same session (source trees confirmed identical via `diff -rq` against
`mruby-rgss/src`, `platformio.ini`, and `build_config.rb` before reuse — no
need to re-run the multi-hour clean cross-build when nothing feeding it had
changed) was linked fresh in this worktree's own `.pio/build/`:

```
$ pio run -e wio_rgss_boot
ld: region `FLASH' overflowed by 675960 bytes
```

Exactly reproduces docs/adr/0140's own "after" number. Then
`env:wio_rgss_boot_heapdbg` (same diagnostic widened-flash environment ADR
0140/0135 used) for a complete, inspectable ELF:

```
$ pio run -e wio_rgss_boot_heapdbg
Flash: [==========]  234.8% (used 1192416 bytes from 507904 bytes)
```

Also exactly reproduces ADR 0140's own post-JPEG-trim number. Both links
produced this session's own real `firmware.map`
(`.pio/build/wio_rgss_boot/firmware.map`, `-Wl,-Map=...` per
`platformio.ini`'s existing `env:wio_rgss_boot` flags — confirmed already in
place, not added here) and `firmware.elf`.

**Parsing the map for real, per-input-section, per-object attribution**
(a small Python parser over the "Linker script and memory map" section, not
a guess from symbol names): every input section contributed to `.text`,
`.rodata`, `.data`, `.ARM.extab` and `.ARM.exidx` was attributed to its real
originating object file or archive member.

One real parsing pitfall found and corrected along the way, worth recording
since it would silently corrupt any future map-based measurement in this
series: GNU `ld`'s ARM port prints an address-space delta (including a
`(size before relaxing)` annotation) rather than the object's real
contribution for the *first* input section belonging to a mergeable-strings
(`SHF_MERGE|SHF_STRINGS`) group — here, `wio_rgss_boot_main.cxx.o`'s
`.rodata._ZN12_GLOBAL__N_18build_uiEPKc.str1.1` showed `0x114ee` (70,894
bytes) in the map while `arm-none-eabi-size` on the real standalone object
file shows its true contribution is 43 bytes (matching the map's own
"before relaxing" footnote). Every *other* `.str1.1`-suffixed entry in the
same map shows its correct, small, real per-object size — only the first
entry in each merged group is inflated this way. Corrected by hand (using
the real per-object `arm-none-eabi-size` value) before aggregating; `.text`
(code) sums were never affected (only `.rodata`, which is placed inside the
`.text` *output* section by this project's own linker script). The
remaining ~11,132-byte (~0.9%) gap between this pass's summed total
(1,203,548) and the real linked flash content (1,192,416) is residual noise
of the same shape, most likely inside `symbol.o`'s own large merged
symbol-name string pool — not investigated further since it does not change
any conclusion below.

## The real breakdown

Real FLASH bytes (`.text` + `.rodata` + `.data` + `.ARM.extab` +
`.ARM.exidx`) by archive/object, from this session's own map:

| archive / object | bytes | what it is |
| --- | --- | --- |
| `libmruby.a` | 967,860 | mruby core + mruby-rgss/lcf/marshal + all compiled bytecode (see below) |
| `liblvgl.a` | 119,970 | LVGL (already its own ADR 0140 category) |
| `libc_nano.a` | 32,010 | newlib (bare-metal libc) |
| `libm.a` | 30,184 | fdlibm (already ADR 0140's own "fdlibm/libm" category) |
| `libSeeed_Arduino_LCD.a` | 21,052 | TFT_eSPI (`TFT_eSPI.cpp.o` alone: 20,934) |
| `libFrameworkArduino.a` | 9,564 | Arduino core (USB stack, SERCOM/UART, startup, wiring) |
| `libgcc.a` | 8,072 | GCC runtime (incl. the ARM EHABI unwinder, see below) |
| `libstdc++_nano.a` | 6,616 | C++ runtime (`std::string`/`vector`, `__cxa_*`) |
| `libFrameworkArduinoVariant.a` | 2,456 | board variant init (`variant.cpp`) |
| `libSeeed_Arduino_FreeRTOS.a` | 2,002 | FreeRTOS (already mostly `--gc-sections`-trimmed) |
| `libSPI.a` | 1,428 | SPI driver |
| `libAdafruit_ZeroDMA.a` | 1,142 | DMA driver (TFT_eSPI's fast SPI writes) |
| `wio_rgss_boot_main.cxx.o` | 900 | this project's own sketch |
| `libnosys.a` + `crt*.o` | ~300 | startup/syscall stubs |
| **TOTAL** | **1,203,548** | (~0.9% over the real 1,192,416 — see the merge-artifact note above) |

`libmruby.a`'s own 967,860 bytes, broken down by member (the part ADR
0140's nm-based pass could not separate from "unclassified" without a real
per-object attribution):

| member(s) | bytes | category |
| --- | --- | --- |
| `gem_init.o` | 456,854 | every gem's compiled Ruby bytecode blob — already ADR 0140's "compiled bytecode" categories |
| `symbol.o` | 86,876 | presym tables + the merged symbol-name string pool (ADR 0140's own "presym tables" category only counted part of this — see the merge-artifact caveat) |
| **`lib.o`** | **86,981** | **mruby-rgss's own C++ glue (`lib.cxx`) — real RGSS API bindings, *and* the still-compiled-in stb_image PNG/BMP decoder (inlined via `#include <stb_image.h>` inside the same file)** |
| `cp932.o` | 75,896 | CP932 tables — matches ADR 0140's own 76,764 almost exactly |
| `vm-cxx.o` + `gc-cxx.o` + `error-cxx.o` | 32,868 | mruby's own VM/GC/error core, compiled as **C++** (not plain C) because `mruby-rgss`/`mruby-lcf`/`mruby-marshal` each have a `.cxx` source — the real, current cost of docs/adr/0134's "real C++ exceptions" default |
| `bigint.o` | 24,705 | mruby-bigint (≈ ADR 0140's own 20,450) |
| **`marshal.o`** | **10,436** | **mruby-marshal's own C++ glue — real save-file serialization** |
| `mrblib.o`, `string.o`, `array.o`, `class.o`, ... (43 more members) | ~166,700 | mruby's remaining native core C (string/array/hash/numeric/kernel/...) — ADR 0140's "mruby core C" category |
| `shinonome.o` | 5,660 | Shinonome fonts (≈ ADR 0140's own 7,762) |
| **`lcf.o`** | **3,255** | **mruby-lcf's own C++ glue — real RPG2000/2003 map-format parsing** |
| `wio.o` | 348 | the wio HAL bridge (`wio.cxx`) |

**C++ exception-support machinery, spanning three archives** (`.ARM.extab`
4,313 + `.ARM.exidx` 12,240 + `vm-cxx.o`/`gc-cxx.o`/`error-cxx.o` 32,868 +
`libgcc.a`'s own unwinder — `unwind-arm.o`/`pr-support.o`/`libunwind.o`,
4,060 — + `libstdc++_nano.a` 6,616): **60,097 bytes**, the real, current
static footprint of "real C++ exceptions are supported at all" on this
target. This is a *gross* figure, not the same thing as docs/adr/0134's own
*net*, actually-measured 20,160-byte reduction from really flipping
`MRUBY_FORCE_NO_CXX_EXCEPTION` (some of this — `libstdc++_nano.a` in
particular — stays linked either way, since `mruby-rgss`/`mruby-lcf` use
`std::string`/`std::vector` regardless of which unwind mechanism `raise`
uses). The two numbers measure different things and do not contradict each
other; ADR 0134's own real before/after relink remains the authoritative
number for what a real toggle would recover.

## Assessment: is any of this a real, safe, JPEG-shaped win?

Checked each significant contributor against real reachability, the same
standard docs/adr/0140 applied to the JPEG decoder — not a guess from size
or name alone:

- **Arduino framework (14,590 bytes: `libFrameworkArduino.a` +
  `libFrameworkArduinoVariant.a` + `libSPI.a` + `libAdafruit_ZeroDMA.a`),
  TFT_eSPI (21,052 bytes), FreeRTOS (2,002 bytes)**: all real, load-bearing
  (this board's actual screen driver, SPI/DMA transfer path, USB/serial
  core, and RTOS), already small after `--gc-sections` (FreeRTOS in
  particular is down to six object files' worth of scheduler primitives —
  most of the library is already gone). All three are vendor libraries
  pulled in via PlatformIO `lib_deps`, not something this repository forks
  or patches the way it already does for `3rd/mruby` — trimming further
  would mean forking/patching a vendor library, a materially bigger and
  riskier undertaking than a single `#define`, for at most a few KB each.
  Not pursued.
- **`libc_nano.a` (32,010 bytes, newlib)**: dominated by float-string
  conversion (`dtoa`/`strtod`/`mprec`/`gdtoa-*`, ~9,000 bytes — real,
  load-bearing: mruby's own `Float#to_s`/`String#to_f`/`sprintf("%f", ...)`)
  and a full civil time/timezone stack (`strftime`/`mktime`/`tzset_r`/
  `timelocal`/`gmtime_r`/`lcltime_r`/`tzcalc_limits`, ~3,000+ bytes) pulled
  in transitively by mruby's own `mruby-time` gem. Checked whether `Time` is
  actually reachable on this target rather than assuming: `Time.now` is
  called for real by `mruby-rpg2k/mrblib/game/lsd_io.rb` (the save-file's
  own OLE-date encoding) and `mruby-rpg2k/mrblib/main.rb` — genuinely
  reachable, not a JPEG-shaped dead path. The C functions behind `Time`'s
  *unused* accessors (`#year`/`#month`/`#strftime`, ...) are real RGSS/
  community-script public API surface this project has never promised to
  drop, and mruby's own gem-init registers their C function pointers into a
  method table regardless of whether this project's own code calls them —
  `--gc-sections` cannot remove a function whose address is taken and
  stored. Trimming this would need the exact same kind of unilateral
  public-API-surface cut ADR 0140 already explicitly declined to make for
  `Math` (`erf`/`erfc`/`asinh`/...) — real, but out of this session's scope
  without a product decision. Flagged as a follow-up option, not pursued.
- **C++ exception-support machinery (60,097 bytes gross, ADR 0134's own
  20,160-byte net figure)**: already investigated, with a real measured
  before/after number, by docs/adr/0134 — and deliberately **not** adopted,
  for a real correctness reason: `mruby-rgss`/`mruby-lcf`/`mruby-marshal`'s
  own `.cxx` files hold live `std::string`/`std::vector` objects on their
  call stacks across `raise`/`break`/non-local-`return` unwind points, which
  `longjmp`-based unwinding would leak (no destructors run) on every such
  unwind. Nothing found in this session changes that: no audit of every
  `.cxx` file for unwind-reachable RAII state has been done since ADR 0134,
  and this session did not do one either — re-affirming, not re-litigating,
  ADR 0134's own conclusion.
- **`mruby-rgss`/`mruby-lcf`/`mruby-marshal`'s own C++ glue (`lib.o` +
  `wio.o` + `lcf.o` + `marshal.o`, 100,020 bytes)**: the single largest
  previously-"unclassified" chunk, now attributed to real object files for
  the first time. Confirmed real, load-bearing application code, not
  removable as a block: `lib.cxx` implements the actual RGSS API bindings
  (`Bitmap`/`Sprite`/`Viewport`/tilemap/...) *and* the still-compiled-in
  PNG/BMP image decoder (`stb_image.h` is `#include`d directly inside
  `lib.cxx`, so its machine code lives inside this same object, not a
  separate one); `marshal.o` and `lcf.o` implement real save-file
  serialization and RPG2000/2003 map-format parsing respectively, both
  confirmed reachable by grep (`Marshal` is used throughout
  `mruby-rpg2k/mrblib/scene/save_load.rb`, `game.rb`, `game/lsd_io.rb`, and
  `mruby-lcf/mrblib/schema.rb`). None of the four is a JPEG-shaped
  "provably unreachable on this target" case; further reduction here is the
  same fine-grained per-function work ADR 0117-0132 already did extensively
  on `mruby-rgss`'s own source, not a single removable block.

## Decision

**No source change.** Every significant contributor to the former
312,105-byte "unclassified" bucket is now attributed to a real object file
or archive, and every one is either genuinely load-bearing (Arduino/
TFT_eSPI/FreeRTOS/newlib's reachable half/the RGSS-family's own C++
implementation) or a real tradeoff already measured and deliberately
declined for a documented correctness reason (C++ exceptions, ADR 0134).
The task's own instruction to prefer an honest "no win here" over forcing a
change is followed on purpose, the same way ADR 0140 preferred a small,
real win over a bigger, riskier one.

## What was verified

- A full, fresh, independently-reproduced link in this session's own
  worktree (submodules, all nine patches, both Unicode tables, GCC 14.2.1):
  `region 'FLASH' overflowed by 675960 bytes` (`wio_rgss_boot`) and
  `1192416` real linked bytes (`wio_rgss_boot_heapdbg`) — both exactly
  reproduce docs/adr/0140's own numbers, confirming this session's build
  environment and this session's `libmruby.a`/`libuni-algo.a` reuse (source
  trees confirmed byte-identical via `diff -rq` first) are trustworthy.
- A real, this-session `firmware.map` parsed for per-object attribution
  (not symbol-name guessing), cross-checked against `arm-none-eabi-size` on
  the real standalone object files for the one anomalous entry found.
- Real reachability checks (`grep`), not assumptions, for `Time`
  (`mruby-rpg2k/mrblib/game/lsd_io.rb`, `main.rb`) and `Marshal`
  (`mruby-rpg2k/mrblib/scene/save_load.rb`, `game.rb`,
  `mruby-lcf/mrblib/schema.rb`) before ruling either load-bearing.

## Consequences

- **wio_rgss_boot still overflows by 675,960 bytes** — unchanged, since
  nothing was changed. This ADR's value is the real breakdown itself and
  the confirmation that this particular bucket is exhausted of
  JPEG-decoder-shaped wins, not a flash reduction.
- **The real lever remains the SD-external-bytecode loader (ADR 0108),
  unbuilt.** `gem_init.o` alone (456,854 bytes, every gem's compiled Ruby
  bytecode) is more than double the entire remaining "unclassified" bucket
  this ADR just resolved — no further per-object-file trimming in the
  Arduino/TFT_eSPI/FreeRTOS/newlib/exception-table space can plausibly
  close a gap that size.
- **Two real, scoped follow-up options this ADR does not pursue, now with
  real numbers attached:**
  - Trimming `mruby-time`'s unused accessor methods (`#year`/`#month`/
    `#strftime`/...) — a few KB of `libc_nano.a`'s civil-time stack,
    reachable only via `mruby-time`'s own always-registered method table,
    not via any call this project's own code makes. Needs the same kind of
    product decision ADR 0140 already declined to make unilaterally for
    `Math` (does this project promise real games' community scripts a full
    `Time` API surface?), plus a `patches/*.patch` against `3rd/mruby`'s own
    `mruby-time` gem the same way the project's other nine mruby-core
    patches work.
  - A real per-function audit of `TFT_eSPI.cpp.o` (20,934 bytes, one
    monolithic vendor object) for board-specific dead paths (e.g. touch
    support the Wio Terminal has no hardware for) — not attempted here:
    `Seeed_Arduino_LCD` is a vendor library taken via PlatformIO `lib_deps`,
    not a submodule this project patches, so pursuing this would be a
    materially different (and first-of-its-kind for this series) class of
    change from every prior ADR's own-source-only trims.
