# 105. Two real cuts to the Wio Terminal's flash overflow: per-symbol dead code elimination and font subsetting

Date: 2026-09-08

## Status

Accepted

## Context

ADR 104 got `env:wio_rgss_boot` linking with zero undefined symbols, but
still ~3.4x over the board's 496 KB flash budget. Two follow-up cuts, each
matching a real, previously-unexploited "this only needs to exist once,
ahead of time" opportunity rather than a runtime feature trade-off:

## Decision

**`-ffunction-sections -fdata-sections` were never set for the wio mruby
cross build.** `build_config.rb`'s `if wio` block never passed either flag
to `conf.cc`/`conf.cxx`, nor did the standalone `3rd/uni-algo` cross build's
own CMake toolchain file — although `env:wio_rgss_boot`'s own link line
already carries `-Wl,--gc-sections` (PlatformIO's own Arduino/LVGL build
needs it for the same reason). Without per-function/per-global sections,
`--gc-sections` can only discard an object file's `.text`/`.data` *entirely*
— one live symbol anywhere in a translation unit keeps every other unused
function and global table in that same file too. Both cross builds now pass
both flags. Confirmed real by direct measurement, not just reasoning: after
the change, the standalone `libuni-algo.a` itself shrank from 241,294 to
145,566 bytes (using the project's own real `cmake/uni-algo-trim.cmake`
mechanism, which an earlier hand-rolled `CMakeLists.txt` for this measurement
had been quietly missing part of), and the real `env:wio_rgss_boot` link's
own flash overflow dropped by 196,012 bytes. As a direct side effect, this
also **closes ADR 103's own flagged gap**: `mruby-rgss/src/iterm.cxx` and
`sixel.cxx` (dead PNG/sixel-encoding code on `psp`/`wio`, since neither
target can ever select a terminal backend) needed no explicit
`PSP_BUILD`/`WIO_TERMINAL` guard after all — confirmed absent from the real
link's own map file entirely (zero occurrences of either object file), now
that the linker can actually see they are unreachable at the function level.

**The embedded Shinonome font shipped the *entire* JIS0208 kanji table,
unconditionally, and half of it was already dead.** Real, measured
breakdown of the linked image (`.pio/build/wio_rgss_boot/firmware.map`,
requested via a new `-Wl,-Map=...` build flag): the `GOTHIC` face's own
`.rodata` — the "full" JIS0208 kanji glyph table `mruby-rgss/src/lib.cxx`'s
`find_char` calls actually look up — was **165,096 bytes on its own, a third
of the entire flash budget**, for all ~6,879 JIS0208-defined glyphs. A
second, serif-style face (`MINCHO`) sat right beside it in
`gen_shinonome_data.rb`'s own output, generated unconditionally alongside
`GOTHIC`, but **grepping the whole repository confirms it is never looked up
anywhere at all** — `RGSS::Font` resolution in `lib.cxx` only ever calls
`find_char` against `GOTHIC`/`LATIN1`/`HANKAKU`. Dropped outright (not
target-gated: it was equally dead on desktop/PSP/wasm).

`GOTHIC` itself cannot be dropped outright — real RPG Maker games need
kanji rendering — but shipping *every* JIS0208 glyph on a target this
flash-constrained, when a specific exported game's dialogue only ever
touches a few hundred distinct kanji, is exactly the kind of thing that
should be decided once, ahead of time, from the game's own text — not
carried as general-purpose capacity on the device. `gen_shinonome_data.rb`
gained a real mechanism for this: `SHINONOME_GLYPH_TEXT_FILE`, an optional
env var naming a UTF-8 text file whose distinct codepoints become an
allow-list for the `GOTHIC` face specifically (`HANKAKU`/`LATIN1` stay
unfiltered — both are small, bounded charsets any game's UI needs
regardless of which kanji it uses). A no-op unless set, so every existing
target's behavior is unchanged by default.

### What was measured

`env:wio_rgss_boot`'s own flash overflow, real `ld` output, each change
applied on top of the last:

| state | FLASH overflow | RAM overflow |
| --- | --- | --- |
| ADR 104 (baseline) | 1,706,256 | 17,584 |
| + `-ffunction-sections -fdata-sections` | 1,510,244 | 17,576 |
| + `MINCHO` dropped, `GOTHIC` filtered to an **empty** glyph corpus | 1,345,148 | 17,576 |

The empty-corpus number is the real, honest one for *this specific boot
test* — `wio_rgss_boot_main.cxx` loads no game data and draws no RGSS
bitmap text at all (its own status/key-echo labels go through LVGL's font,
not Shinonome), so an empty allow-list is not a synthetic best case, it is
what this firmware today actually needs. It is deliberately **not** a claim
about what a real game would fit in — that needs an actual per-game export
step (scanning `LMU`/`LMT`/`LDB` text for its own distinct kanji), which
does not exist yet. `docs/adr/0104`'s own "no game data is loaded" caveat on
this environment still holds.

Combined: **361,108 bytes recovered (~21.2%)** of ADR 104's original
1,706,256-byte overflow, with zero behavior change to any existing target
and zero risk to real games' kanji rendering (the subsetting mechanism is
opt-in and untouched by default).

### What still does not exist

- **The firmware still does not fit** — 1,345,148 bytes over flash, still
  ~2.7x the budget. This was never going to close the whole gap; see the
  next two items for what's left unexamined.
- **No real per-game glyph corpus or export step.** The mechanism exists;
  nothing produces or consumes a real one yet. This is the natural next
  lever once actual game-data loading exists on wio (ADR 7's own P3).
- **LVGL's 40 KB `LV_MEM_SIZE` (`app/wio/lv_conf.h`) was examined but left
  alone.** It is the exact size of the RAM overflow's own `.bss` entry
  (`lv_mem_core_builtin.c.o`'s `work_mem_int`), and was already a
  deliberate, reasoned choice (its own comment: "the whole firmware...
  shares 192 KB, so keep this modest"), not an accident — and it is shared
  with `env:wio` (the already-working P1 bring-up firmware), so shrinking it
  without a real boot to validate against risks a regression there for an
  unverified gain here. Left for whoever can actually flash and watch it
  run, real hardware or Renode.

## Consequences

- **A permanent, real fix, not scratch-only**: both `-ffunction-sections
  -fdata-sections` (`build_config.rb`) and the `SHINONOME_GLYPH_TEXT_FILE`
  mechanism (`gen_shinonome_data.rb`) are committed, no-op-by-default
  changes any future wio (or other target's) work benefits from without
  having to rediscover them.
- **`docs/adr/0104`'s own flagged `iterm.cxx`/`sixel.cxx` gap is closed**,
  confirmed by direct measurement rather than reasoned about in the
  abstract.
- **The remaining gap is now better characterized, not just a raw number.**
  A real linker map (kept on, via `-Wl,-Map=...`, since this environment is
  not wired into CI or a default `pio run` either way) makes the next
  candidates visible: `symbol.o`'s own name-string table (~74 KB), the
  `una::detail` NFD normalization tables (~94 KB total), and LVGL's own
  memory pool sizing remain open, real leads for a future pass.
