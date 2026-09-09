# 126. Strip the dead font-directory scan for wio

Date: 2026-09-09

## Status

Accepted

## Context

Following the same "unconditionally linked, provably unreachable on wio"
pattern ADR 0125 found in `profiler.cxx`, `mruby-rgss/src/default_font.cxx`
turned out to have the identical shape at smaller scale.

The gem looks up a fallback UI font by scanning directories
(`$RPG_DEFAULT_FONT`, directories the executable registers via
`add_default_font_dir`, `/fonts`, `assets/fonts`) with `opendir`/`readdir`,
using a `std::vector<std::string>` of candidate directories and
`std::string` throughout. The file's own pre-existing comment already
explained why this can never find anything on wio: its bare
`arm-none-eabi` newlib has no `dirent` implementation at all, so the file
stubs `opendir`/`readdir` to always return null there. On top of that,
`add_default_font_dir` -- the only way a non-empty `g_app_dirs` could ever
exist -- is called only from `src/main.cxx`, the desktop entry point;
`app/wio/src` never calls it. So on wio, `probe()` was guaranteed to reach
its `return std::string();` fallback every time, through a `std::vector`
push loop and several always-failing `opendir` calls, none of which the
prior code short-circuited at compile time.

## Decision

Gated the entire directory-scan implementation (the `std::vector`/
`std::string`-based `is_dir`/`is_readable_file`/`has_font_ext`/
`first_font_in`/`probe`, and the inline `dirent` stub they relied on)
behind `#ifndef WIO_TERMINAL`/`#else`, the same macro `profiler.cxx`
(ADR 0125) and `terminal.cxx` already gate their own dead-on-wio code
behind. The `#else` branch is two trivial functions matching
`default_font.hxx`'s exact signatures: `add_default_font_dir` becomes a
no-op (never called on wio anyway), and `default_font_path()` returns a
static empty `std::string` directly -- the same answer `probe()` always
produced there, just without the vector/opendir detour to reach it.

### What was verified

- Both branches compile cleanly (host `g++ -std=c++17 -Wall -Wextra`, zero
  errors/warnings).
- The preserved (non-wio) branch is unchanged content, only re-indented
  under the new `#ifndef`/`#else` (diffed directly to confirm).
- Real `arm-none-eabi-g++` cross-compile with this board's actual flags
  (`-mcpu=cortex-m4 -mfloat-abi=hard -mfpu=fpv4-sp-d16 -Os -fno-rtti`,
  matching `build_config.rb`): **1,608 -> 90 bytes of `.text`** for this
  one translation unit -- a 1,518-byte reduction.
- `RGSS.default_font_path`'s only wio call path (`lib.cxx`'s
  `default_font_path_m`) still gets the same `""` it always got on this
  board; `RGSS::Font` still falls back to the bundled shinonome bitmap
  font exactly as before.

### What was not verified

- No full wio firmware link (same sandbox limitation as ADR 0125) -- the
  isolated `.o` delta is the real, measured number for this file, not a
  confirmed final linked-firmware delta.
- No full desktop/psp/wasm/android rebuild; trusted on the byte-for-byte-
  unchanged preserved branch instead, same as ADR 0125.

## Consequences

- A small additional real flash win for wio, zero behavior change --
  `default_font_path()` was already permanently `""` there.
- Desktop/wasm/android keep the full directory-scanning implementation
  unchanged; PSP also keeps it (scoped to `WIO_TERMINAL` only, not
  `PSP_BUILD`, same flash-budget-vs-capability distinction ADR 0125 drew:
  PSP's `dirent` works for real and has flash headroom to spare).
- Confirms the broader answer to "could `std::string`/`std::vector` used
  elsewhere in these gems be replaced by mruby's own objects instead":
  no -- most of the remaining usage (PNG/font decode scratch buffers in
  `lib.cxx`) is internal algorithm state that would get *worse* (RAM-
  boxed `mrb_value` elements instead of raw bytes) from that change, and
  the handful of genuine Ruby-string-interop sites don't reduce flash by
  themselves since `libstdc++`'s `basic_string`/`vector` stay linked in
  for every other real (non-wio-dead) use. This file was the one place
  where the container use itself was dead code, not merely a design
  question -- the same category `profiler.cxx` was, and now the only two
  found of that shape.
