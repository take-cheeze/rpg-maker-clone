# 106. Skip NFD normalization on the Wio Terminal

Date: 2026-09-08

## Status

Accepted

## Context

ADR 105's own "what still does not exist" list named uni-algo's NFD
normalization tables (~94 KB, `una::detail::stage1/2/3_decomp_nfd` and
`stage1/2_ccc_qc`) as an open candidate for the Wio Terminal's flash budget,
explicitly deferred pending confirmation it is safe to drop there.

`una::norm::to_nfd_utf8` has exactly two call sites, both in
`mruby-rgss/src/lib.cxx`, and both real, tested, non-dead code — this is not
another `MINCHO`/`iterm.cxx` situation:

- `to_nfd(mrb_state*, mrb_value)`, exposed as `RGSS.to_nfd` and covered by
  `mruby-rgss/test/test.rb`'s own assertion. Its one real caller is
  `mruby-rgss/mrblib/lib.rb`'s `exist_with_ext` — the helper every asset
  lookup (graphics, audio) goes through — as a second-chance fallback when
  the exact filename does not resolve.
- `Bitmap#_init_file`'s own fallback: the same retry, inline, for bitmap
  loads specifically.

Both exist for a real, narrow bug class: a macOS-authored zip or archive
stores filenames in NFD form (each accented character as base+combining
mark) while the game's own data references them in NFC (one precomposed
codepoint), or vice versa. Genuinely worth keeping on desktop/PSP, where 94
KB is noise.

## Decision

Both call sites now short-circuit under `WIO_TERMINAL`: `to_nfd` returns its
input unchanged, and `Bitmap#_init_file`'s retry block compiles out
entirely. This is a real, scoped behavior change, not a no-op — accepted for
two reasons together, not either alone:

- This project's own asset-export pipeline for the Wio Terminal writes one
  consistent normalization form; the fallback exists for filenames arriving
  from *outside* that pipeline (an archive authored elsewhere), which is not
  how assets reach this target's SD card.
- The cost of being wrong is graceful, not fatal: a filename that genuinely
  needs the fallback simply fails to resolve the same way a truly-missing
  file already does (`exist_with_ext` returns `nil`, `Bitmap#_init_file`
  returns `nil`) — no crash, no corrupted state, an already-handled path
  guarded by unwrapped Ruby the codebase already expects to happen.

Both changes are behind `#ifdef WIO_TERMINAL`/`#ifndef WIO_TERMINAL`
specifically (not a build-wide define): every other target's behavior,
including the existing `RGSS.to_nfd` test assertion, is byte-for-byte
unchanged. Verified real, not assumed: `ctest -R mruby_test` still passes
100% after the change, `cmake --build build` still links clean.

### What was measured

Real relink, `env:wio_rgss_boot`, on top of ADR 105's own state:

| state | FLASH overflow |
| --- | --- |
| ADR 105 (sections + font trim) | 1,345,148 |
| + NFD skipped on wio | 1,248,724 |

**96,424 bytes recovered**, matching the map-based ~94 KB estimate closely
(the small gap is the surrounding call-site code itself, also eliminated).

### What still does not exist

The firmware still does not fit — 1,248,724 bytes over flash, ~2.5x the
496 KB budget. `symbol.o`'s own name-string table and LVGL's memory pool
sizing (ADR 105's own remaining candidates) are still open. Per-gem
measurement (a real breakdown by `mrbgem`, not guessed) now shows
`mruby-rpg2k`'s own precompiled `mrblib` bytecode (~780 KB) and mruby's core
interpreter (~312 KB) dominate what remains — a much larger lever than
anything left in uni-algo, and a fundamentally different kind of problem
(the actual RPG2000/2003 engine's own Ruby code, not a droppable
convenience feature).

## Consequences

- Wio Terminal games must have their assets referenced in the same
  normalization form the export pipeline writes — already true today, so no
  observed behavior change for any real exported game, only for a
  hypothetical asset arriving through some other path.
- If a future wio asset pipeline ever ingests archives from outside this
  project's own export step, this decision should be revisited alongside
  that work, not assumed to still hold.
