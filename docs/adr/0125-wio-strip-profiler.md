# 125. Strip the dev-only profiler/tracer for wio

Date: 2026-09-09

## Status

Accepted

## Context

Looking for standard-library-driven flash cost (the "skeleton" ADR 0108
identified as this port's real remaining floor, not `mruby-rpg2k`'s own
Ruby), `mruby-rgss/src/profiler.cxx` -- a Chrome-trace-format profiler and
periodic stderr summary line (frame timing, per-section timing, memory/GC
type-count sampling, allocator churn) -- turned out to be unconditionally
compiled and initialized on every target, wio included, with no
`build.name`/macro guard anywhere (`build_config.rb`, `mruby-rgss/mrbgem.rake`
were both checked; neither mentions it).

Its own header (`include/profiler.hxx`) already documents that the
subsystem is inert until enabled: "the default (unprofiled) build pays only
a single predicted branch per frame and per section." True for *runtime*
cost, but irrelevant to *flash*: `profiler_configure()`/`profiler_trace_start()`
(the only two ways `g_enabled`/tracing ever turn on) are called only from
`src/main.cxx` -- the desktop entry point's `--profile`/`--profile_trace`
flag handling. Grepping every other entry point this project has
(`app/wio/src/main.cxx`, `app/wio/src/wio_rgss_boot_main.cxx`,
`app/psp`) turns up no call to either, anywhere. `RGSS::Profiler`'s Ruby
bindings (`profiler_init`, registered unconditionally from
`mruby-rgss/src/lib.cxx`'s gem-init) are this project's own dev API, not
exposed by any RPG Maker format a real game script could reach. So on wio
specifically, `g_enabled` is permanently, provably false -- there is no
call path, C++ or Ruby, that ever sets it -- while the code for when it
*would* be true stays fully linked regardless.

That code is real weight: `report()`/the four Chrome-trace writers
(`trace_raw`/`trace_complete`/`trace_counter`/`trace_instant`) alone carry
14 `std::snprintf` calls, several formatting doubles (`%.2f`/`%.3f`/`%.0f`),
which is exactly the newlib-on-embedded trap of pulling in the float-to-
string conversion core; `live_type_snapshot()`'s `std::sort` plus
`g_sections`' `std::map<std::string, SectionAgg>`; a `kTypeNames[]` table
built from every `mrb_vtype`; and ten `mrb_define_module_function`
registrations for `RGSS::Profiler`'s own methods.

## Decision

Gated the whole heavy implementation behind `#ifndef WIO_TERMINAL` /
`#else` inside `profiler.cxx` itself, reusing the identical, already-
proven macro this exact gem's sibling file (`terminal.cxx`) already gates
its own desktop-only sixel/iTerm2 backend behind, and that `build_config.rb`
already defines unconditionally for the wio cross-build
(`t.defines << 'WIO_TERMINAL'`, next to the comment explaining terminal.cxx's
own use of it). No new macro, no `build_config.rb`/`mrbgem.rake` change at
all -- this is a pure, self-contained edit to one file.

The `#else` (wio) branch is a from-scratch, minimal stand-in that keeps
every call site `lib.cxx` actually reaches on wio working identically:
`profiler_note_frame_drop()`/`profiler_note_idle()` (the main-loop calls)
and `ProfilerScope`'s use of `profiler_section_begin()`/`_end()` (the
`gfx.zorder`/`gfx.invalidate`/`gfx.lvgl` sections). Every public function
keeps its exact signature from `profiler.hxx`, so `lib.cxx`/`terminal.cxx`
need zero changes. Scoped to `WIO_TERMINAL` only, not `PSP_BUILD` --
unlike `terminal.cxx`'s exclusion (a *capability* question: neither board
can display a terminal at all), this is the same *flash-budget* judgment
call ADR 0107's battle trim already made: PSP has real flash/storage
headroom this board does not, and the profiler is a legitimate, harmless
dev tool there.

### What was verified

- Both branches compile cleanly against this project's real headers
  (`mruby.h` with `patches/mruby-gc-type-live-counts.patch` applied,
  vendored `lvgl.h`, the gem's own `profiler.hxx`/`terminal.hxx`) -- host
  `g++ -std=c++17`, zero errors; the wio branch additionally clean under
  `-Wall -Wextra`.
- The preserved (non-wio) branch's content is byte-for-byte identical to
  the original file (diffed directly): the only changes outside the new
  `#else` branch are hoisting the two always-needed `#include`s above the
  `#ifndef` and dropping one now-redundant `<cstdint>` (already pulled in
  transitively by `profiler.hxx`) -- both confirmed safe by the same
  successful compile.
- Real cross-compile of `profiler.cxx` alone with `arm-none-eabi-g++`,
  this board's actual flags (`-mcpu=cortex-m4 -mfloat-abi=softfp
  -mfpu=fpv4-sp-d16 -Os -fno-exceptions -fno-rtti`, matching
  `platformio.ini`): **9,926 -> 102 bytes of `.text`** for this one
  translation unit -- a **9,824-byte reduction**, on the real target CPU
  and real optimization level, not a host-architecture proxy.

### What was not verified

- **No full wio firmware link.** This sandbox has no PlatformIO /
  Arduino-SAMD-core / full LVGL-config toolchain, so the *linked firmware*
  delta is not directly measured. The isolated `.o` delta above is a
  ceiling, not a guaranteed final number, for one specific reason: several
  of the removed `snprintf` calls use `%f`/`%g`, and `mruby-rgss/src/lib.cxx`
  itself calls `snprintf` with `%g` (formatting `Color`/`Tone#to_s`) --
  code that *does* ship on wio. If newlib's float-to-string core is a
  single shared blob pulled in by any `%f`/`%g` use anywhere in the final
  link (typical for `nano.specs`), that cost was already being paid by
  `lib.cxx`'s own formatting and remains paid regardless of this change;
  the guaranteed-unique part of the 9,824 bytes is the `std::map`-based
  section aggregation, the JSON/trace string-building, the `kTypeNames[]`
  table, and the ten Ruby method registrations -- real and unique either
  way, just not yet separated from the float-core question by a real link.
- **No full desktop (CMake/SDL2) rebuild.** This sandbox has no system
  SDL2 and the project vendors it from source (a from-scratch build this
  session's time budget did not spend); the preserved branch's byte-for-
  byte-unchanged content (verified above) is the basis for trusting the
  desktop/psp/android/wasm builds are unaffected, not a full link of any
  of them.

## Consequences

- A real, if not yet fully link-measured, flash win for wio, at zero
  behavioural change: `g_enabled` was already permanently false there in
  the original code (nothing ever calls `profiler_configure(true, ...)`
  on this board); this ADR makes that unreachable state explicit at
  compile time instead of leaving it as a reachable-in-principle runtime
  branch.
- `psp`/desktop/wasm/android keep the full profiler, `--profile`/
  `--profile_trace` and `RGSS::Profiler` unchanged.
- The float-to-string-core overlap with `lib.cxx`'s own `%g` usage is a
  real open question this ADR does not resolve -- worth settling with a
  real `wio_rgss_boot` relink (the same measurement ADR 0107/0115/etc.
  used) whenever that toolchain is available, both to confirm the real
  number and to decide whether trimming `lib.cxx`'s own `Color`/`Tone`/
  `Rect#to_s` formatting is a further, related lever.
