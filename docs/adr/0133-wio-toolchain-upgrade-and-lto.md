# 133. Upgrade the wio toolchain to unlock -flto; the single largest win in this series

Date: 2026-09-10

## Status

Accepted

## Context

The previous session found `-flto` genuinely broken on this target: a real
link failure, `unresolvable R_ARM_THM_CALL relocation against
__aeabi_ldivmod`, caused by `atmelsam@9.0.0`'s own pinned
`toolchain-gccarmnoneeabi` (GCC 7.2.1, released 2017) mishandling a 64-bit-
division helper LTO's own late link-time codegen pass discovers a need for
only after normal library resolution has already run. The workaround tried
at the time (an explicit trailing `-lgcc`) did not help, and fixing
PlatformIO's own generated link-line ordering was judged out of scope for a
flag change.

Asked directly to update the toolchain and use the flags anyway, the actual
fix turned out to be exactly that: PlatformIO's registry carries a current
Arm GNU Toolchain release (`platformio/toolchain-gccarmnoneeabi@1.140201.0`
== GCC 14.2.1) as an installable package, independent of what `atmelsam`'s
own platform manifest defaults to. PlatformIO's `platform_packages`
project-level override (documented for exactly this "pin a newer tool than
the platform's own default" case) swaps it in per-environment.

## Decision

**`platformio.ini`**: `env:wio` and `env:wio_rgss_boot` both gained

```ini
platform_packages =
    platformio/toolchain-gccarmnoneeabi@1.140201.0
```

and, in `build_flags`:

```
-flto
-fno-ident
-fmerge-all-constants
-Wno-implicit-function-declaration
```

`-flto`/`-fno-ident`/`-fmerge-all-constants` are the three flags from the
prior session's own write-up (cross-TU inlining/dead-code elimination on
top of `--gc-sections`; drop the per-object GCC-version comment; more
aggressive cross-TU constant deduplication than the default
`-fmerge-constants`). `-Wno-implicit-function-declaration` is new, and
unrelated to size: GCC 14 made implicit function declarations a hard error
by default (a real upstream GCC behavior change, not a project choice),
which broke compiling Seeed's own vendored `Seeed_Arduino_FreeRTOS`
library's `.c` files outright (`xSemaphoreCreateMutexStatic` and three
siblings, gated behind a `configSUPPORT_STATIC_ALLOCATION` macro
`FreeRTOSConfig.h` doesn't set, so newlib POSIX shims that call them only
ever had an implicit declaration to begin with) — downgraded back to a
warning so a toolchain bump doesn't also require patching a vendored
framework package this project does not control.

**`build_config.rb`**: the wio cross-build's own `cc`/`cxx` flags gained the
same `-flto`/`-fno-ident`/`-fmerge-all-constants` (this compile step has no
C files of its own beyond what mruby itself already handles, so no
`-Wno-implicit-function-declaration` needed here). `conf.archiver.command`
switched from plain `arm-none-eabi-ar` to `arm-none-eabi-gcc-ar`: `-flto`
object files carry IR rather than final machine code (GCC's default "slim"
LTO objects), so building and re-indexing `libmruby.a` needs the LTO
plugin loaded to read a member's real symbol table — `gcc-ar` loads it
automatically where plain `ar`/`ranlib` are not guaranteed to. The
standalone `uni-algo` cross-build (a manual `arm-none-eabi-g++`/`gcc-ar`
invocation outside the mruby rake system, since uni-algo ships no
`library.json` PlatformIO can resolve on its own) picked up the identical
flag set and archiver so the whole dependency chain is LTO-consistent.

## What was verified

A full clean rebuild at every layer: `MRUBY_TARGET=wio rake` from a clean
`3rd/mruby/build/wio`, a fresh standalone `uni-algo` cross-build, and
`rm -rf .pio/build/wio_rgss_boot` before the real link (to rule out any
cached-object artifact) — the number reproduced exactly across two
independent clean builds:

```
before (ADR 132, GCC 7.2.1, no LTO): region `FLASH' overflowed by 842344 bytes
after  (GCC 14.2.1 + -flto -fno-ident -fmerge-all-constants):
         region `FLASH' overflowed by 651824 bytes
```

**A real, reproduced 190,520-byte reduction** — by far the largest single
change in this entire series, bigger than every prior ADR's own trim
combined. `.bss` also dropped for real (24,700 -> 19,080 bytes) and `.data`
slightly (12,992 -> 12,768), a genuine ~5.8 KB RAM win alongside the flash
one — plausible given seven years of GCC's own `-Os` heuristics and IPA
passes improving, on top of `-flto` now actually running (`lto-wrapper`
logged "using serial compilation of 16 LTRANS jobs" during the real link,
confirming LTO fired across the whole dependency chain — `build_flags`
reaches every object PlatformIO's own build environment compiles, Arduino
framework and LVGL included, not just this project's own sources, so this
is closer to a true whole-program LTO than a partial one).

`env:wio` (the actual shipped bring-up firmware, no mruby) also built
clean end to end with the new toolchain and flags: 149,000/507,904 bytes
flash, 17,428/196,608 bytes RAM, a real `firmware.bin` produced.
`env:wio_walk`, scoped outside this ADR's `platform_packages` override,
rebuilt unaffected on the original toolchain (72,464 bytes flash, matching
its pre-existing baseline exactly) — confirming the override is genuinely
per-environment, not a global toolchain swap that could silently affect
targets this ADR never touched.

## Consequences

- **This makes every prior byte-shaving ADR in the series look smaller by
  comparison** — a real, if slightly humbling, data point: the biggest
  single lever this whole effort found was not a code trim at all, but a
  seven-years-stale pinned compiler version.
- **CI picks this up automatically.** `platform_packages` lives in
  `platformio.ini` itself, not an environment variable or a workflow step,
  so `.github/workflows/build.yml`'s own `wio` job downloads the same
  pinned toolchain the next time it runs, with no separate CI change
  needed.
- **`env:wio_rgss_boot`/`env:wio` are the only environments now on a newer
  toolchain than `atmelsam@9.0.0` ships by default.** `wio_walk` and
  `wio_sd_upload` were deliberately left on the platform's own default —
  neither links mruby or LVGL, so neither had anything to gain from LTO,
  and there was no reason to widen the toolchain-version surface further
  than the two environments that actually benefit.
- **Still nowhere near fitting** (651,824 bytes over, down from 842,344) —
  a huge relative improvement, but the same structural conclusion every
  ADR in this series has landed on stands: closing the rest needs the
  SD-external-bytecode loader ADR 108 never finished, not more compiler
  flags.
