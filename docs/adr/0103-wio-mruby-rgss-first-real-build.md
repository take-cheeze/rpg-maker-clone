# 103. mruby-rgss actually compiles and links for the Wio Terminal, for the first time

Date: 2026-09-08

## Status

Accepted

## Context

ADR 7 named the Wio Terminal's mruby+RGSS+LVGL stack a design record from the
start — "not yet a working firmware... the numbers above are budget
estimates to be replaced with real size/heap measurements in Phase 1." ADR 99
went further and said so explicitly: *"the Wio firmware does not link
`libmruby.a` at all... this ADR's mechanism is validated in isolation, ready
for whichever slice actually starts the interpreter."* `build_config.rb`
already defines a `MRUBY_TARGET=wio` cross build (`rpg_maker_gems`, the same
gem set psp compiles), but nothing in this repository's own CI, build
scripts, or CMake has ever actually run it to completion — there is no
`MRUBY_TARGET_NAME=wio` branch in the root `CMakeLists.txt` at all (only
`host`/`emscripten`/`android`), and `app/wio`'s own `wio_mruby_sd_smoke`
PlatformIO environment (ADR 99) links a deliberately bare mruby core, not
this one.

Running `MRUBY_TARGET=wio rake` for real, directly, surfaced four genuine,
previously-undiscovered bugs — not by inspection, by the compiler and linker
actually objecting, the same way ADR 99's own real-hardware pass did for a
different subsystem.

## Decision

**A real `hal-wio-io` gem**, mirroring `hal-posix-io`/`hal-win-io`'s existing
shape: mruby-io's own `spec.build.gems.one? { |g| g.name =~ /^hal-.*-io$/ }`
selection means any correctly-named HAL gem satisfies it, so this is a
first-class alternative, not a patch. Wio's bare `arm-none-eabi` newlib is
close enough to POSIX for plain file I/O — `open`/`close`/`read`/`write`/
`lseek`/`fstat`/`unlink` all compile and, once `app/wio/src/sd_syscalls.cxx`'s
`WIO_WITH_SD` syscalls are linked into the real firmware, work — but has none
of `hal-posix-io`'s much wider POSIX surface: no `<dirent.h>` at all (a hard
`#error`, confirmed by trying), no `lstat`. The new HAL:

- Implements exactly what a real RPG2000/2003 game reaches through this
  exporter's own file access (`File.open`/`.exist?`/`.file?`/`.delete` — the
  full real call-site list across `mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`'s
  own mrblib), composing path-based `stat`/`lstat` from `open`+`fstat`+
  `close` rather than needing functions the platform has neither of.
- Returns `ENOSYS` for the rest of the ~30-function contract (locking,
  process spawning, symlinks, `select`/`dup`/`fcntl`) — no process model, no
  symlinks on FAT, and nothing reachable from this exporter's own RPG2000/2003
  output ever calls them, the same "drop what nothing calls" reasoning ADR 98
  already applied to onigmo.
- `sd_syscalls.cxx` gained `_unlink` (`SD.remove`), the one missing syscall
  the HAL's own `File.delete` call site needs.

**`mruby-dir` excluded outright for wio** (`build_config.rb`), not given its
own HAL: nothing in the psp/wio gem set calls `Dir` at all — the desktop/
Android history that made this gem mandatory project-wide was specifically
about `mruby-rpgxp`'s `Dir.glob` patch, and `mruby-rpgxp` is already excluded
from wio's own `single_format_only` set. Verified, not assumed: zero `Dir.*`
call sites in `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss`'s mrblib, and nothing
`add_dependency`s it back in the way the next bug shows onigmo was.

**`WIO_TERMINAL` now actually defined** in the wio cross build. It gates
`mruby-rgss/src/wio.cxx`'s real LVGL/TFT_eSPI HAL on and the desktop-only
sixel/iTerm2 `terminal.cxx` backend off — PSP's own equivalent, `PSP_BUILD`,
was already there; wio's was simply never added, so neither half of that
guard had ever actually fired for this target before now.

**`mruby-rgss/src/lib.cxx` and `default_font.cxx`'s own `<dirent.h>` use**
(a `Fonts/` folder scan and a default-font directory search, both already
degrading gracefully to "not found" on any `opendir` failure) now skip real
`dirent.h` under `WIO_TERMINAL`, the same way `terminal.cxx` already skips
its own platform-specific code. A real directory listing has no meaningful
answer on this board to begin with — a project ships one font at a fixed
path, decided at export time, not discovered on-device.

**A real, previously-invisible regression in ADR 98's own onigmo trim**:
`3rd/mruby-marshal`'s `mrbgem.rake` `add_dependency`s `mruby-onig-regexp`
*unconditionally* — the top-level `conf.gem mruby-onig-regexp do ... end
unless single_format_only` exclusion `rpg_maker_gems` already had never
actually stopped mruby-marshal from pulling it right back in as a
dependency. **ADR 98's claim that psp/wio drop onigmo has, it turns out,
never actually been true** — nothing had linked far enough to notice.
Fixed two ways, together:

- `marshal.cpp`'s `utility` constructor no longer hard-requires the `Regexp`
  class via `mrb_class_get` (only `mruby-onig-regexp` defines it at all — no
  mruby core gem does), which would otherwise turn *every* `Marshal.dump`/
  `.load` call into an immediate `NameError` the moment onigmo is actually
  gone. `mrb_class_defined` guards it first; the one real use site (a
  `cls == regexp_class` pointer comparison) already treats `nullptr` exactly
  as "not a Regexp," since no live object's class pointer is ever null. This
  matters for real: `mruby-rpg2k/mrblib/main.rb`'s own save/load path calls
  `Marshal.dump state.to_h` / `Marshal.load(data)` directly, so this is not
  a theoretical fix.
- `mrbgem.rake`'s `add_dependency` becomes conditional (`unless %w[psp
  wio].include?(build.name)`), now that it is actually safe.

Both live in `patches/mruby-marshal-psp-wio-onigmo-optional.patch`, applied
by `cmake/build-mruby.cmake` the same way the existing mruby/mruby-stringio
patches are (project-owned submodules this session has no push access to).

### What was measured

`MRUBY_TARGET=wio rake` — for the first time — completes end to end and
produces a real, complete `libmruby.a` whose "Included Gems" summary matches
ADR 98's originally-intended set exactly: `hal-wio-io`, the core extension
gems, `mruby-lcf`, `mruby-marshal`, `mruby-rgss`, `mruby-rpg2k`, `mruby-
stringio` — no `mruby-onig-regexp`, no `mruby-rpgxp`/`rpgvx`/`wolf`/`mvjs`,
no `mruby-dir`.

| | bytes |
| --- | --- |
| `libmruby.a`, summed `.text` | 1,884,788 |
| `libmruby.a`, summed `.data` | 147,920 |
| `libmruby.a`, summed `.bss` | 13,457 |
| **Total** | **2,046,165** |

This is a **pre-link archive total**, not a firmware size: every object
file's sections summed regardless of whether the final link would actually
reference them (no `--gc-sections` has run), compiled with `enable_debug`
(full DWARF, no `-O`/size tuning beyond the `MRB_HEAP_PAGE_SIZE`/
`KHASH_INITIAL_SIZE` knobs ADR 47 already established), and biggest by far
is `mruby-lcf`'s own `gem_init.o` (776,622 bytes — the cdump'd `schema.rb`+
`lcf.rb` bytecode ADR 99 already measured a smaller, RITE-binary form of).
It answers a narrower but real question — **does this actually compile and
archive at all** — for the first time since the target was defined.

### What still does not exist

- **No real flash/RAM number.** That needs LVGL and uni-algo actually
  cross-compiled for `arm-none-eabi` (PSP's own `app/psp/CMakeLists.txt`
  shows the shape; wio has no CMake integration at all yet, only this rake
  invocation) and a real link into a PlatformIO firmware, which is where
  `wio.cxx`'s genuine `Arduino.h`/`TFT_eSPI.h` dependency has to be satisfied
  for real — worked around here only for compilation, via a new,
  `RGSS_WIO_STUB_HEADERS`-gated escape hatch (a no-op unless a caller points
  it at declaration-only stub headers; nothing in this repo sets it).
- **ADR 99's own five patches (colon3, `$!`, `defined?`, the NoMemoryError
  reentrant-alloc fix, GC type counts) are still not wired into any wio
  build path**, real or this one — they only apply through
  `cmake/build-mruby.cmake`'s `rpg2k_add_mruby`, which nothing yet calls for
  `MRUBY_TARGET_NAME=wio`. This rake invocation bypassed that entirely.
- **`mruby-rgss/src/iterm.cxx` and `sixel.cxx` have no `PSP_BUILD`/
  `WIO_TERMINAL` guard at all**, unlike `terminal.cxx` (which dispatches to
  both and is itself correctly gated off). Their real PNG/sixel-encoding
  implementations — dead code on psp/wio, since nothing there can ever
  select a terminal backend — still compile in unconditionally. A real,
  same-shape trim opportunity (iterm.cxx alone measured 33,255 bytes in the
  archive above), left for its own pass rather than folded in here.

## Consequences

- **Verified, not just built once.** The full sequence — `rake` from a clean
  build dir, twice, byte-identical `arm-none-eabi-size` totals both times —
  and the desktop build: `ninja` + `ctest` (all 9 tests, including
  `mruby_test`'s 2052+ assertions covering `mruby-marshal`'s own test suite)
  pass unchanged after the `marshal.cpp`/`mrbgem.rake` patch, confirming the
  `Regexp`-optional change is behavior-neutral wherever `Regexp` already
  exists (every target but psp/wio).
- **This is a real step in ADR 7's own P1, not P1 itself.** "mruby boots, a
  test LVGL screen draws on the LCD... buttons reach `RGSS::Input`" — ADR 7's
  own exit criteria — needs the still-missing pieces above: LVGL/uni-algo for
  ARM, a real PlatformIO link, and the ADR 99 patches wired in. What this ADR
  closes is narrower and was, until today, not even attempted: whether the
  Ruby/C++ half of the stack (the actual game logic and the RGSS/LVGL
  wrapper this port would run) compiles for this target *at all*.
