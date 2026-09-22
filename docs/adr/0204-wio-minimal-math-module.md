# 204. Replace mruby-math with a minimal Math module on the Wio Terminal

Date: 2026-09-22

## Status

Accepted

## Context

docs/adr/0140 and 0141 both named `Math` as a flash lever and left it
alone. `fdlibm`/`libm` came to 30-35 KB of the image, but everything in
`Math` is "reachable from a *game's own* community Ruby script", so cutting
it would be a public-API decision. docs/adr/0202 then established that on
Wio this concern does not apply. Wio ships mruby-rpg2k alone, RPG2000/2003
games carry no Ruby, and the build links no compiler or eval. So the only
callers `Math` can have on Wio are the engine's own gems.

Those gems use two members. `Math.sin` has 5 call sites (screen shake,
flying battlers, and the like) and `Math::PI` has 6. The count comes from
parsing every `.rb` file in mruby-rpg2k/-lcf/-rgss and mruby-stringio. None
of the core gems' own `mrblib` uses `Math` at all, and no C/C++ source looks
it up by name.

mruby's core `mruby-math` still registers about 30 module functions:
`sin`/`cos`/`tan`, the inverse trig functions, the hyperbolics and their
inverses, `exp`/`log`/`log2`/`log10`/`log1p`/`expm1`, `sqrt`, `cbrt`,
`hypot`, `frexp`/`ldexp`, `erf`/`erfc`. Gem init takes each one's address,
so `--gc-sections` has to keep every libm routine behind them.
`s_erf.o` alone is 3,964 bytes. The map's archive-member table shows
`math.o` as the object that pulls in 26 separate libm members.

## Decision

- **`app/wio/mruby-math-wio`**, a new gem shaped like
  `app/wio/hal-wio-io`. It defines `Math`, `Math::DomainError`, `Math::PI`,
  `Math::E` and `Math.sin`, using the same `sin(mrb_as_float(...))` body as
  upstream `math.c`. Its header comment explains why it is minimal, and how
  to grow it.
- **`build_config.rb`**: on Wio, `rpg_maker_gems` loads this gem instead of
  `conf.gem core: 'mruby-math'`. Every other target is unchanged. Wio's
  `Math` is now strictly smaller than upstream's, not different: every
  member it has behaves exactly as mruby-math's does.
- **`scripts/wio_dropped_gems_check.rb`** (docs/adr/0202's CI tripwire)
  gains a Math allow-list, `MATH_PROVIDED` (PI, E, DomainError, sin). Any
  other `Math.x`/`Math::X` fails, and so does `include Math`/`extend Math`,
  because the bare `cos` it would enable cannot be checked. Its self-test
  gets positive and negative Math cases; `MyMath.cos`, for example, must not
  count. Planting `Math.cos(1)` in a scratch copy of the tree made it fail.
  So a future engine call to `Math.cos` fails CI with instructions, instead
  of raising `NoMethodError` on the board.

## What was verified

Fresh `MRUBY_TARGET=wio rake` cross-builds and `flock`-serialized relinks,
on top of docs/adr/0202:

| build | before | after | delta |
| --- | ---: | ---: | ---: |
| `wio_rgss_boot` baseline, FLASH overflow | 639,788 | 619,012 | -20,776 |
| `wio_rgss_boot` bc2cpp, FLASH overflow | 3,536,308 | 3,515,660 | -20,648 |

The bc2cpp pair was built from the same working tree as docs/adr/0202's
bc2cpp "after", which is this row's "before". The three generated
`*_compiled_gen.cpp` files are byte-identical between the two builds, apart
from the build-directory path, so the delta is this change alone. The
bc2cpp-compiled code links against the minimal module with no unresolved
symbol.

By object: `libm.a` goes from 30,184 to 11,808 bytes (the libm routines
lib.cxx, LVGL, TFT_eSPI and the mruby core still call directly stay).
`math.o` goes from 2,355 to 176 (the new gem's `math.o`), and `symbol.o`
shrinks by 259 because fewer presyms remain. RAM is unchanged. The link
resolves every symbol.

## What was not verified

- No boot on hardware or under Renode. `Math.sin`'s body is upstream's,
  line for line, and the CI check ensures nothing on Wio calls anything
  else.

## Consequences

- About 20.8 KB less flash, the largest of this session's Wio rounds.
  Cumulative from docs/adr/0199 through this one, `wio_rgss_boot`'s
  baseline overflow goes 684,008 -> 619,012 (-64,996).
- Wio's `Math` is deliberately partial. The engine's own code is the only
  client, and CI now enforces that its use stays inside the provided set.
  Growing the set costs one C function plus one allow-list entry.
- `mruby-time` could take the same treatment next. Its unused accessors pull
  in newlib's civil-time stack (`strftime`, `mktime`, tz handling;
  docs/adr/0141 estimated "a few KB"). The engine's only non-LSD use is
  `main.rb`'s timestamp string. That is a separate, smaller round, not done
  here.
