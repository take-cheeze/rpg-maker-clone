# 104. A real PlatformIO link of mruby+RGSS+LVGL for the Wio Terminal now succeeds — and overflows flash by ~3.4x

Date: 2026-09-08

## Status

Accepted

## Context

ADR 103 got `MRUBY_TARGET=wio rake` to compile and archive `libmruby.a` for
the first time, but named two things it explicitly had not done: "no real
flash/RAM number... needs LVGL and uni-algo actually cross-compiled for
`arm-none-eabi`... and a real link into a PlatformIO firmware." This ADR
attempts exactly that: a new `env:wio_rgss_boot` PlatformIO environment
(`app/wio/src/wio_rgss_boot_main.cxx`) linking that `libmruby.a` against a
standalone `arm-none-eabi` cross build of `3rd/uni-algo` and PlatformIO's own
LVGL/`Seeed_Arduino_LCD` build — the real firmware shape ADR 7's own P1 exit
criteria needs, not the measurement-only archive ADR 103 stopped at.

The first real link attempt surfaced a chain of genuine bugs, none of them in
`mruby-rgss`'s own game logic — every one was a real ABI or toolchain
mismatch between how `libmruby.a` had been built and how the actual firmware
links, only visible once a real, complete link was attempted end to end.

## Decision

**`RGSS_WIO_STUB_HEADERS` (ADR 103) is unsound for a real link, not just
incomplete.** It compiles `wio.cxx` against declaration-only stand-ins for
`Arduino.h`/`TFT_eSPI.h`, but `TFT_eSPI` is a real stateful C++ class (with a
`Print` base and its own fields), and `wio.cxx` embeds a `TFT_eSPI g_tft`
global *by value*. A stub with no matching fields gives `g_tft` the wrong
object size and layout; the real `TFT_eSPI` methods (compiled separately,
against the real class) then read and write past a too-small global. The
stub's free functions were wrong too — `pinMode`/`digitalRead`/`delay`/
`millis` lacked `extern "C"` and used the wrong parameter types, so `wio.o`
looked for C++-mangled symbols (`_Z7pinModehh`) no framework object ever
defines. A **new escape hatch, `RGSS_WIO_ARDUINO_INCLUDES`**
(`build_config.rb`), points `wio.cxx`'s compile at the real PlatformIO
framework headers instead — extracted from a real `pio run -v` compile of a
framework file (Arduino core, CMSIS, CMSIS-Atmel, the board's `variant.h`,
`Seeed_Arduino_LCD`) since the PlatformIO package cache paths are host- and
package-version-specific and cannot be hardcoded. This produces a `wio.o`
that is genuinely ABI-compatible with the real link: same `extern "C"`
linkage, same parameter types, same `TFT_eSPI` layout.

**A bare `arm-none-eabi-gcc` resolved to the wrong compiler entirely.**
`build_config.rb` only ever named the compiler by bare command
(`conf.cc.command = 'arm-none-eabi-gcc'`), resolved via `PATH`. On this
machine that resolves to the distro's own `arm-none-eabi-gcc` package
(13.2.1) — not PlatformIO's bundled `toolchain-gccarmnoneeabi` (7.2.1), which
the real firmware link always uses. Two different compiler majors silently
disagreeing on ABI and codegen defaults is not something flag-matching can
paper over: it manifested as `__aeabi_read_tp` undefined at link time (see
below), traced back to the distro package's own `-fstack-protector-strong`
default eventually being ruled out as the actual cause, but the deeper,
correct fix is the same regardless — **use the same compiler that links.**
`build_config.rb` now prefers PlatformIO's own copy
(`~/.platformio/packages/toolchain-gccarmnoneeabi/bin/`) when present,
falling back to plain `PATH` resolution otherwise (a standalone,
measurement-only build never needs to agree with a real link — see ADR 103).

**`__aeabi_read_tp` undefined, for real, even with the correct toolchain.**
GCC's C++11 thread-safe static-local-variable initialization guards compile,
on ARM EABI, to an inline fast path that reads the current thread ID via
`__aeabi_read_tp` — a helper no `arm-none-eabi` newlib multilib in
PlatformIO's own toolchain defines (single-threaded bare-metal firmware has
no thread pointer to read). `mruby-rgss`'s stb_image-derived image decoders
and `mruby-lcf`'s cp932 conversion both have function-local statics with
non-trivial initializers, so both hit this. PlatformIO's own Arduino
framework compiles already build every C++ file with `-fno-threadsafe-
statics` for exactly this reason; `libmruby.a` now does too.

**PlatformIO's bundled `arm-none-eabi-g++` (7.2.1) defaults to `gnu++14`,
not new enough.** `mruby-lcf/src/lcf.cxx` includes `<optional>`, and
`3rd/uni-algo`'s own `config.h` hard-errors below C++17. Every other cross
build here (host, wasm) got C++17 "for free" because the system/emsdk
compiler's own default standard already happened to be new enough — this is
the first target where that assumption broke. `conf.cxx.flags << '-std=gnu++17'`.

**`mruby-io`'s `file.c` doesn't compile on this newlib at all.**
`path_getwd` (backing `Dir.getwd`/`File.expand_path`) declares
`char buf[MAXPATHLEN]` after `#include <sys/param.h>`, true on glibc and most
BSD/Darwin libcs — but this toolchain's bare-metal `arm-none-eabi` newlib's
own `sys/param.h` defines `PATHSIZE`, not `MAXPATHLEN`, so the file fails to
compile outright with the correct toolchain in place (the wrong toolchain
used in earlier attempts silently had its own, different `MAXPATHLEN`
available and never caught this). `patches/mruby-io-maxpathlen-fallback.patch`
adds the same `#ifndef MAXPATHLEN #define MAXPATHLEN 1024` fallback the
file's own `_WIN32` branch already carries a few lines up, applied via the
established `apply_mruby_patch.bash` mechanism (`3rd/mruby` is not a fork
this session can push a real upstream fix to).

**PlatformIO's own `atmelsam`/`arduino` builder never links `libstdc++`.**
The framework itself builds with `-fno-exceptions -fno-rtti` and never needs
the C++ runtime, so nothing in a stock PlatformIO project ever requests it.
`mruby-rgss`'s `lib.cxx`/`lcf.cxx` genuinely use it (`std::string`,
`std::vector`, including their internal `std::__throw_bad_array_new_length`
overflow guard). `platformio.ini`'s `env:wio_rgss_boot` now adds `-lstdc++`
to `build_flags` explicitly.

**`hal-wio-io` was missing its own gem entry points.** `mrb_hal_wio_io_gem_init`/
`_gem_final` — the functions mruby's generated `gem_init.c` actually calls —
were never written (found only by a real link attempt; an archive-only build
never catches a missing symbol). `mruby-io`'s own core `src/io.c` also calls
plain `dup()`/`waitpid()` directly (`IO#dup`'s `symdup`, and
`fptr_finalize`'s process-reaping path) — outside this HAL's own
`mrb_hal_io_*` contract, and genuinely unreachable in practice (no pid-bearing
`IO` object can exist, since `mrb_hal_io_spawn_process` always fails), but
newlib declares both without ever defining them for this target, so the link
still needs *something*. Both gained `ENOSYS`-stub definitions in
`hal-wio-io/src/io_hal.c`.

**`mruby-rgss/mrbgem.rake` was missing `app/wio` on its own `lv_conf.h`
search path**, unlike its existing PSP entry — this gem's own `lib.cxx`
calls into LVGL directly (`vp_refresh_overlay`/`gfx_snap_to_bitmap`), so its
rake-driven compile must see the *same* `lv_conf.h` the real firmware's own
LVGL build uses, or the two disagree on what LVGL actually compiled in
(`LV_USE_LOG`/`LV_USE_SNAPSHOT`) and the link fails on `lv_log_add`/
`lv_snapshot_take` — confirmed for real linking `env:wio_rgss_boot` before
this line existed for `wio`, the same class of bug PSP's own entry already
exists to prevent.

**`-Os`, not the default `-O3`.** `mruby`'s own `gcc.rake` default is `-O3`;
PSP's cross build deliberately keeps it (UMD-backed storage, speed matters
more than size there). The Wio Terminal's 512 KB internal flash does not
have that luxury — `t.flags << '-Os'` for wio only.

### What was measured

With every fix above in place, `env:wio_rgss_boot` **links with zero
undefined symbols** — the entire chain of ABI mismatches above is resolved.
It still fails, on the flash/RAM size check alone:

```
region `FLASH' overflowed by 1706256 bytes
region `RAM' overflowed by 17584 bytes
```

against this board's real budget (`pio`'s own header): SAMD51P19A, 192 KB
RAM, 496 KB flash. No `firmware.elf` is produced — `ld` refuses to emit one
once a region overflows — so there is nothing to boot yet, under Renode or
otherwise.

Pre-link archive totals (the same caveat as ADR 103: every object file's
sections summed regardless of whether the real link's `--gc-sections`
actually keeps them):

| archive | `.text` | `.data` | `.bss` | total |
| --- | --- | --- | --- | --- |
| `libmruby.a` (`-Os`, real headers) | 1,639,582 | 148,016 | 13,574 | 1,801,172 |
| `liblvgl.a` | 224,682 | 0 | 40,965 | 265,647 |
| `libuni-algo.a` | 241,278 | 0 | 16 | 241,294 |

Within `libmruby.a`, the largest single object is `shinonome.o` — the
embedded Japanese bitmap font — at 182,472 bytes, roughly a third of the
entire flash budget by itself; `lib.cxx`'s own object (128,709) and mruby's
symbol table (`symbol.o`, 128,072) are the next largest.

### What still does not exist

- **A firmware that fits.** ~3.4x over flash, ~1.09x over RAM, even after
  `-Os`. Closing this is a real, substantial follow-up (embedded-font
  strategy, further gem trimming, possibly `-flto`/`--gc-sections` tuning
  beyond what this environment's default flags already do) — genuinely out
  of scope for the ABI/link work this ADR closes, not attempted here beyond
  `-Os` itself.
- **No boot, real or emulated.** ADR 7's own P1 exit criteria ("mruby boots,
  a test LVGL screen draws... buttons reach `RGSS::Input`") needs a firmware
  that links to completion first. This ADR gets the link itself to a clean,
  ABI-correct state; it does not get a bootable image.
- **`iterm.cxx`/`sixel.cxx`'s missing `PSP_BUILD`/`WIO_TERMINAL` guard**
  (ADR 103's own flagged gap) is still open. Their archive-level contribution
  was re-measured but not re-verified against a successful, `--gc-sections`'d
  link (none exists yet to check against), so whether guarding them would
  move the flash number at all is not yet known — left for the fitting pass
  above rather than guessed at here.

## Consequences

- **The Wio Terminal's mruby+RGSS+LVGL link is now provably ABI-correct.**
  Every remaining blocker is a size budget problem, not a correctness one —
  a meaningfully different, more tractable class of work than ADR 103 left
  off with.
- **`RGSS_WIO_ARDUINO_INCLUDES` and the toolchain-path fix are both real,
  permanent parts of `build_config.rb`** (gated no-ops unless a caller sets
  the former), not scratch-only like ADR 103's own `RGSS_WIO_STUB_HEADERS`
  remains for pure measurement.
- **P1 is closer but not done.** The next real step is a memory-budget pass
  (this ADR's own "what still does not exist" above), then an actual boot
  attempt — real hardware or Renode — once a firmware small enough to link
  to completion exists.
