# 140. Re-measure the real wio_rgss_boot flash overflow, and drop the unreachable JPEG decoder on wio

Date: 2026-09-10

## Status

Accepted

## Context

Asked to re-verify the `wio_rgss_boot` flash overflow the previous session's
own docs/adr flagged but never acted on (docs/adr/0135 measured 684,080
bytes) and look for a real, safe reduction, the first step was to distrust
that number and rebuild fresh, per this whole series' own established
discipline (a linker's own overflow message, not a size-proxy guess).

### Rebuilding from scratch surfaced two real build-reproducibility gaps

Neither is specific to this session's own change -- both are pre-existing
gaps in how a clean checkout reaches the state every prior ADR's own
measurement assumed:

1. **A plain `MRUBY_TARGET=wio rake`, run directly rather than through
   `cmake/build-mruby.cmake`, skips every patch that CMake's own build
   applies** (`scripts/apply_mruby_patch.bash` against `patches/*.patch` --
   nine of them, docs/adr/0103's onigmo-optional fix for
   `mruby-marshal`'s `mrbgem.rake` chief among them for this measurement:
   without it, `MRUBY_TARGET=wio rake` fails outright trying to autoconf
   onigmo for a bare-metal `arm-none-eabi` host triplet with no working C
   compiler in that context). Applied all nine by hand before rebuilding
   (`scripts/apply_mruby_patch.bash <dir> <patch>` per file, matching
   `cmake/build-mruby.cmake`'s own COMMAND list exactly); every one applied
   cleanly (none already applied, none rejected).
2. A from-scratch worktree checkout of this repository does not check out
   any submodule (`3rd/mruby`, `3rd/uni-algo`, `3rd/stb`, `3rd/lvgl`,
   `3rd/quickjs`, `3rd/mruby-marshal`, `3rd/mruby-onig-regexp`,
   `3rd/mruby-stringio`, `3rd/mgem-list`) -- `git submodule update --init
   --recursive` was needed before any of this would build at all.

Neither gap changes what any prior ADR measured (both are build-environment
setup, not a source or config difference), but both are real friction this
session hit that a from-scratch rebuild anywhere else would hit too.

### The real, current number

A full clean rebuild -- `libmruby.a` (wio target, real C++ exceptions, no
`-flto`, GCC 14.2.1 + `-fno-ident -fmerge-all-constants`, matching
docs/adr/0135's committed config exactly) plus a matching standalone
`uni-algo` cross-build (same flags, confirmed by `arm-none-eabi-size` on
`data.o`: `.text` 145,440 bytes, 29 bytes off ADR 133's own cached build --
noise, not a regression), then `rm -rf .pio/build/wio_rgss_boot && pio run
-e wio_rgss_boot`:

```
region `FLASH' overflowed by 684624 bytes
```

Consistent with docs/adr/0135's 684,080 (a 544-byte drift, plausibly the
8ab43c9 bc2cpp follow-up's own small unrelated `build_config.rb` touch, or
just accumulated noise across two clean-room rebuilds) -- **the overflow is
real, current, and essentially unchanged since ADR 135**. Nobody acted on it
in between, as the task description already said.

### Inspecting the real linked binary

`arm-none-eabi-size`/`nm` alone can't see a binary that fails to link, so
`env:wio_rgss_boot_heapdbg` (docs/adr/0135's own diagnostic environment --
FLASH widened to 2 MB via `app/wio/renode/oversized_flash_debug.ld`, never a
real hardware config) was used to get a real, complete ELF for `arm-none-
eabi-nm --print-size --size-sort -C` and `arm-none-eabi-size -A` to inspect
directly. A rough categorisation of every symbol in that ELF by name
pattern:

| category | bytes | symbols |
| --- | --- | --- |
| mruby-rpg2k compiled bytecode (`gem_mrblib_mruby_rpg2k_proc_*`) | 364,866 | 6,091 |
| unclassified (Arduino framework, TFT_eSPI, FreeRTOS, newlib, C++ unwind tables, mruby-rgss's own C++ glue) | 312,105 | 2,991 |
| mruby core C (`mrb_*`, gc, vm) | 95,423 | 766 |
| LVGL (`lv_*`) | 81,809 | 599 |
| CP932 forward + reverse tables | 76,764 | 7 |
| other compiled bytecode (mruby core mrblib, string-ext, ...) | 37,104 | 1,051 |
| fdlibm/libm (trig, exp/log, erf, ...) | 34,832 | 78 |
| mruby presym tables | 27,588 | 2 |
| mruby-rgss compiled bytecode | 25,852 | 614 |
| stb_image + stb_truetype | 25,653 | 97 |
| mruby-bigint | 20,450 | 85 |
| mruby-lcf compiled bytecode | 19,613 | 488 |
| Shinonome fonts | 7,762 | 10 |

The two single-symbol standouts, `cp932_table` and `cp932_reverse_table`
(37,944 bytes each, 76,764 combined once `--gc-sections` shares a few common
bytes) are **not a bug**: docs/adr/0111 already made this exact tradeoff
deliberately, moving `utf8_to_cp932`'s reverse-lookup table from a ~38 KB
*heap allocation* (invisible to every flash measurement, and RAM is the
harder-confirmed blocker per docs/adr/0135-0136) to this flash-resident
`const` array, at a documented and accepted flash cost. Reverting it would
trade flash for RAM in exactly the wrong direction this project has already
reasoned through -- not touched here.

Among the rest, one item stood out as genuinely, provably dead code on this
target specifically, not merely "not the current hot path": `stb_image`'s
JPEG decoder.

### JPEG decoding is unreachable on wio, not merely unused

`mruby-rgss/src/lib.cxx`'s own file comment already documents (docs/adr/
0025) that the *default* `RGSS::Bitmap::EXTENSIONS` list
(`mruby-rgss/mrblib/lib.rb`) includes `:jpg`/`:jpeg` only because "the RPG
Maker XP RTP genuinely ships .jpg title screens" -- an RPG Maker XP/VX
concern. `wio` is a `single_format_only` build (`build_config.rb`): it
compiles `mruby-rpg2k` alone, never `mruby-rpgxp`/`mruby-rpgvx`/`mruby-wolf`
(docs/adr/0098), so no Ruby path on this target can ever select the maker
that `.jpg` candidate exists for. `RPG2k::Game#initialize`
(`mruby-rpg2k/mrblib/main.rb`) installs `RGSS::Bitmap::RPG2K_EXTENSIONS`
instead -- `[:bmp, :png, :xyz]`, measured directly against a real
`RPG_RT.exe` under wine ("no `.jpg`/`.jpeg` candidate ... at all") -- before
any asset load this engine's own boot sequence performs. Every
`stbi__jpeg_*` function `stb_image.h` compiles in is therefore dead weight
on wio specifically, the same shape as the six formats (`STBI_NO_GIF`/
`PSD`/`TGA`/`HDR`/`PIC`/`PNM`) already excluded a few lines above it in the
same file for the same "not reachable from any loader in this codebase"
reason -- except this one is reachable everywhere except wio (and psp,
itself also `single_format_only`, left untouched here to keep this change
scoped to the one target this session measured).

## Decision

**`mruby-rgss/src/lib.cxx`**: `#define STBI_NO_JPEG` under `#ifdef
WIO_TERMINAL`, placed with the existing unconditional `STBI_NO_*` block
just above `STB_IMAGE_IMPLEMENTATION`/`#include <stb_image.h>`. Scoped to
`WIO_TERMINAL` only (not a broader `single_format_only`-shaped check) so
desktop/wasm/android/psp -- none of which this session measured or
verified -- keep their exact current behaviour. `bmp_decode_into`'s own
JPEG-vs-PNG `stbi_failure_reason()` diagnostic-string quirk (the file's own
"no SOI" comment) is a cosmetic string difference on an already-failing
load path, gated behind the pre-existing `g_bitmap_decoder_ran` flag for
correctness either way -- not a functional change.

## What was verified

A full clean rebuild at every layer (fresh `libmruby.a`, fresh `uni-algo`,
`rm -rf .pio/build/wio_rgss_boot` before each real link):

```
before (this session's own re-measurement, GCC 14.2.1, no -flto): region `FLASH' overflowed by 684624 bytes
after  (STBI_NO_JPEG added under WIO_TERMINAL):                   region `FLASH' overflowed by 675960 bytes
```

**A real, reproduced 8,664-byte reduction.** Confirmed at the symbol level,
not just the overflow delta: a fresh `wio_rgss_boot_heapdbg` build (the
same widened-flash diagnostic environment docs/adr/0135 committed) dropped
from 1,201,080 to 1,192,416 bytes of real linked flash content (the same
8,664-byte delta), and `arm-none-eabi-nm` on that ELF shows zero symbols
matching `stbi__jpeg`/`stbi__idct`/`stbi__decode_jpeg`/`jpeg_huff` after the
change (previously present, including a 4,648-byte `stbi__load_main`
specialisation and a 716-byte `stbi__idct_block`, among others).

Not booted under Renode this round (unlike docs/adr/0135/0136, which found
real boot-time bugs invisible to a link-only check) -- this change removes
an already-provably-unreachable code path rather than touching anything on
`RPG2k`'s own live boot/load call graph, and `bmp_decode_into`'s callers are
unchanged. A future session doing further work on this target should still
boot it under Renode before trusting any further size change, per the
lesson docs/adr/0135/0136 already drew.

## Consequences

- **wio_rgss_boot still overflows by 675,960 bytes.** This is a real,
  small, safe win (~1.3% of the overflow this session started with) — not
  a fix, and not claimed as one. The task's own instruction to prefer a
  correctly-scoped small win over forcing a bigger, riskier one is
  followed here on purpose.
- **RAM, not flash, is still the harder-confirmed blocker.** docs/adr/0135
  and 0136 already measured `wio_rgss_boot` needing 296,152 bytes of RAM
  against a real 196,608-byte board budget -- a 99,544-byte shortfall this
  ADR does nothing about. Closing the flash gap alone would still not
  produce a booting build.
- **The real lever every ADR in this series has already pointed at remains
  unbuilt**: docs/adr/0108's SD-external-bytecode loader (not holding the
  compiled program's classes/methods/bytecode as one big live/flash-
  resident block at once). The category breakdown above puts a number on
  why: `mruby-rpg2k`'s own compiled bytecode alone is 364,866 bytes, more
  than half of the current overflow by itself, and it is real gameplay
  logic -- not something a further per-symbol trim can meaningfully cut
  into without an actual change in how/when it is loaded.
- **Two follow-up options this ADR does not pursue, with what is already
  known about each:**
  - *Trim rarely-used `Math` module methods* (`erf`/`erfc`/`asinh`/
    `acosh`/`atanh`/`expm1`/`log1p`/`log2`/`cbrt`, part of the 34,832-byte
    fdlibm category above) from mruby's own core `mruby-math` gem. Real
    RGSS only ever documents `sqrt`/`sin`/`cos`/`tan`/`atan2`/`exp`/`log`/
    `pow`/`hypot`, but this project's own engine only ever calls `sqrt`
    directly (`build_config.rb`'s own comment) -- everything else in
    `Math` is reachable from a *game's own* community Ruby script, not
    just this engine's code, so cutting it is a real public-API-surface
    decision this session's own "does not remove real gameplay
    functionality silently" scope explicitly rules out doing unilaterally.
    Would need a product decision on which `Math` methods wio actually
    promises to support, then a small patch to `mruby-math`'s own
    `mrbgem.rake`/`math.c` (project has no push access to fork mruby
    itself, so this needs the same `patches/*.patch` + `apply_mruby_patch`
    treatment as the other mruby-core patches already carried).
  - *The 312,105-byte "unclassified" category* (Arduino framework/
    TFT_eSPI/FreeRTOS/newlib/C++ unwind tables/mruby-rgss's own glue) is
    the single largest bucket after mruby-rpg2k's own bytecode and was not
    broken down further in this session -- a real linker-map-based
    per-object-file pass (`firmware.map`, already produced by every
    `wio_rgss_boot` link via `-Wl,-Map=...`) could plausibly find more
    real, safe wins the same shape as this ADR's, but needs more time than
    this session had to do with the same rigor (a real relink to prove
    each candidate, not a guess from symbol names alone).
