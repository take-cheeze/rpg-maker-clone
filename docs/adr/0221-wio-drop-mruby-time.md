# 221. Drop mruby-time from the wio build

Date: 2026-09-23

## Status

Accepted

## Context

The default `wio_rgss_boot` firmware overflows the Wio Terminal's
507,904 B flash by 624,164 B at 7ed1848e.

It links `mruby-time`, and through `time.o` it links newlib's
`strftime`/`mktime`/`localtime_r`/`gmtime_r`/`tzset` family. It also links
the Arduino core's `_gettimeofday`.

The board has no set real-time clock. `Time.now` there is 1970-01-01 plus
the uptime.

Only two places in the Ruby wio builds name `Time`:

- **`RPG2k#bug_report_stamp`** (`main.rb`) stamps the F8 bug-report file
  name. On wio, `strip_wio_inline_helpers.rb` inlines it into
  `#dump_bug_report`.
- **`Game::State.ole_now`** (`game/lsd_io.rb`) stamps a save. It falls back to
  `NO_CLOCK_TIMESTAMP` through a `rescue StandardError`. `game/lsd_io.rb`
  is not in wio's rbfiles today (the LSD interop trim).

No wio C source looks `Time` up. `mruby-io`'s `File.mtime`/`atime`/`ctime`
return a `Time`, but no wio Ruby calls them. No gem in the wio set declares
`add_dependency 'mruby-time'`: only mruby-rpgxp does, and mruby-io lists it
as a test dependency only.

## Decision

- **`build_config.rb` leaves `mruby-time` out when `conf.name == 'wio'`.**
- **`scripts/strip_wio_clock.rb` rewrites wio-only build copies of the
  source.** `build_config.rb`'s `wio_strip_clock` applies it:
  - The bug-report name becomes `bugreport_frame<Graphics.frame_count>.md`.
    That name is unique per F8 press within a session, as the uptime-based
    clock was.
  - `ole_now` returns `NO_CLOCK_TIMESTAMP` directly. The rescue that would
    otherwise swallow the `NameError` goes with it.
- **Any leftover `Time` fails the build.** The script refuses any output
  that still names `Time`, and every rbfile of mruby-rpg2k, mruby-lcf and
  mruby-rgss passes through it. It runs after `wio_strip_inline_helpers` and
  before `wio_strip_debug_rbfiles`.
- **CI runs the same check.** `scripts/wio_strip_scripts_check.rb` runs the
  script over every mrblib file, including `game/lsd_io.rb`.

## Consequences

Measured with a full `wio_rgss_boot` link (the baseline configuration of
`scripts/wio_bc2cpp_measure.bash`):

- **Flash:** 1,132,068 → 1,116,580 B. The `FLASH` overflow falls from
  624,164 to 608,676 B, which is **−15,488 B**.
- **Static RAM:** 32,296 → 32,148 B (−148 B).
- **Objects no longer linked:**
  - mruby-time's `time.o` and `gem_init.o`;
  - newlib's `strftime`, `mktime`, `localtime_r`, `gmtime_r`, `tzset`,
    `tzcalc_limits` and `month_lengths` objects;
  - the Arduino core's `_gettimeofday`.

Bug-report files on wio are now named by frame count, not by a fake 1970
date.

If a wio save path returns, it stamps saves 2000-01-01 (`NO_CLOCK_TIMESTAMP`)
instead of 1970 plus uptime. Both are placeholder dates, and RPG_RT accepts
both.

### Also investigated, not changed

- **`Math.sin` as a table.** The saving would be small.
  - libm's `sin` → `__kernel_sin`/`__kernel_cos`/`__ieee754_rem_pio2`/
    `__kernel_rem_pio2` chain stays linked either way:
    `mruby-rgss/src/lib.cxx`'s `Bitmap#wave_blt` calls `std::sin`. RPG2k's
    wave show/erase transitions use it on wio (`scene/map.rb`'s
    `@fade_bmp.wave_blt`).
  - Replacing `Game::Screen#update_shake`'s `Math.sin` would free only
    `s_sin.o` (144 B) and `mruby-math-wio` (176 B).
  - A 256-entry Float table would cost more than that in bytecode.
- **Float ↔ string conversion.** Who links each object:
  - `fmt_fp.o` (1,564 B), through `numeric.o` (`Float#to_s`/`#inspect`) and
    `sprintf.o`. Any interpolated or inspected Float reaches it, and so do
    mruby's own error messages. It cannot be shown unreachable, so it stays.
  - `readfloat.o` (5,580 B), through `string.o` alone (`String#to_f`, a
    ROM-table core method). No wio Ruby calls `to_f` on a String, but
    removing it needs a new mruby core patch that makes `String#to_f` raise.
    That is left as a follow-up.
  - newlib `strtod` + `gdtoa-gethex`/`hexnan` (about 4.9 KB), through
    `mruby-marshal`'s float reader. No wio Ruby uses `Marshal`, but
    mruby-rgss depends on the gem. Also a follow-up.
  - newlib `_printf_float` + `_dtoa_r` (about 4.8 KB), through the Arduino
    core's `dtostrf`, which `WString` references. That is framework code,
    outside the engine.
