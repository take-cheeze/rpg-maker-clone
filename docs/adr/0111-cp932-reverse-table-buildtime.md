# 111. Build the CP932 reverse table at build time, and fix a real data-corruption bug found while doing it

Date: 2026-09-09

## Status

Accepted

## Context

`mruby-lcf/src/lcf.cxx`'s `utf8_to_cp932` (the encode direction -- used
whenever any string gets written back out, e.g. every save-game field)
built its own reverse-sorted copy of the entire CP932 table **at runtime**,
the first time the function was ever called:

```cpp
static const std::vector<std::pair<uint16_t, uint16_t>> reverse_table = [] {
  std::vector<std::pair<uint16_t, uint16_t>> t;
  t.reserve(cp932_table_len);
  for (size_t i = 0; i < cp932_table_len; ++i)
    t.emplace_back(cp932_table[i].second, cp932_table[i].first);
  std::sort(t.begin(), t.end());
  return t;
}();
```

9,486 entries, 4 bytes each: a real, ~38 KB **heap allocation**, invisible
to every flash/RAM relink measurement this whole series has relied on
(`.bss`/`.data` don't cover a runtime `std::vector`), on a board whose
192 KB RAM budget ADR 107 already got to fit with zero margin. The first
real save a game on this board attempted would very likely have exhausted
RAM outright.

## Decision

**Generate both directions at build time.** `mruby-lcf/cp932_to_unicode.rb`
now emits a second array, `cp932_reverse_table` (unicode -> cp932, sorted
by unicode with CP932 as the tiebreak -- reproducing, at build time, the
exact order `std::pair`'s default `operator<` gave the old runtime sort,
which matters because the table is many-to-one in this direction and the
tiebreak decides which CP932 byte a round-tripped character encodes back
to). `lcf.cxx`'s `utf8_to_cp932` now just points at it directly, the same
way `cp932_to_utf8` already used the flash-resident forward table --
no heap allocation, no `<vector>` include, nothing left to build lazily.

### A real, pre-existing bug found verifying the fix

The first version of this fix failed its own verification (a byte-for-byte
comparison against the old runtime-built table) with results that made no
sense for *either* version being correct: entries near the end of
`cp932_table` read as garbage or as a wraparound of the table's own start,
depending on how the test was built. Isolating it (single translation
unit, no cross-TU linking involved) pointed at the array itself, not the
comparison: **`cp932_table`'s real compiled size was smaller than
`cp932_table_len` claimed**, so every relink of this project's own
`env:wio_rgss_boot` for months has been binary-searching past the end of
a `const` array -- undefined behavior, not merely `-Wcomment` noise.

Root cause: `cp932_to_unicode.rb` writes each entry's on-disk comment field
(free-form CP932 text, frequently containing bytes that decode to a
literal backslash) straight into a `//` comment. A `//` comment ending in
`\` splices onto the *next source line* -- line continuation happens
*before* comment tokenization in both C and C++ -- silently swallowing that
line's own `{ 0x.., 0x.. },` entry into the comment. A real generated
`cp932.cc`: 74 lines ending in a bare backslash, each deleting the array
entry after it with no compiler error (only a `-Wcomment` warning, easy to
miss among the hundreds of other real warnings a full build already
produces). `cp932_table_len` was never adjusted to match, so the array's
own true (shorter) bound was invisible to every reader -- both directions
of the table have been quietly missing entries, and the last several dozen
reads past the true end have been undefined behavior, this whole time.

Fixed by never writing anything but backslash-free printable ASCII into a
comment: `safe_comment` byte-filters the raw field to `0x20-0x7e` minus
`0x5c`. Comments are purely decorative (nothing parses them back out), so
there is no information lost that mattered -- the previous mojibake
(CP932 text pushed through as raw bytes, rendering as `<27>` in any UTF-8
terminal) is gone as a side effect, not a goal in itself.

### What was verified

- **Zero backslash-terminated lines** in a real regenerated `cp932.cc`
  (was 74).
- **The array reads correctly to its real end**: `cp932_table[9485]` (the
  last of 9,486) is a genuine table entry, not garbage -- confirmed by
  direct inspection before and after the fix.
- **The new build-time `cp932_reverse_table` is byte-for-byte identical**
  to what the old runtime code would have built, *given the corrected
  forward table*: a host-side test that reproduces the exact old
  construction (`emplace_back` + `std::sort`) against the fixed
  `cp932_table` and diffs it entry-by-entry against the new array --
  9,486 entries, zero mismatches.
- **A real functional round-trip**, through the actual compiled
  `LCF.cp932_to_utf8/utf8_to_cp932` (via a real `mrb_state`, not a
  reimplementation): ASCII, the well-known ideographic space (CP932
  `0x8140` = U+3000), a run of mixed kanji, and -- specifically --
  `0xfc4a`/`0xfc4b`, the last two entries in the table and exactly where
  the out-of-bounds read used to land. All round-trip correctly.

### What it costs

A real relink, `env:wio_rgss_boot`, on top of ADR 109+110's own combined
state:

| state | FLASH overflow |
| --- | --- |
| ADR 109 + 110 (schema blob + font SD offload) | 1,095,748 |
| + build-time CP932 reverse table | 1,132,652 |

**+36,904 bytes of flash**, consistent with the reverse table's own raw
size (9,486 x 4 bytes = 37,944, minus what `--gc-sections` still finds
shareable). This gives back a real chunk of today's earlier savings, but
trades it for removing a ~38 KB RAM allocation this board cannot afford
and a real, silent data-corruption bug -- not a close call.

## Consequences

- `utf8_to_cp932` no longer allocates anything at all: both encode and
  decode directions are now pure flash-resident binary search, matching
  every other static table this project ships.
- The CP932 forward table itself is measurably *more correct* than it was
  before this ADR, independent of the RAM question: every codepoint that
  used to fall in one of the 74 swallowed-comment gaps is now actually
  present and reachable, on every target this gem builds for (desktop,
  wasm, PSP, wio alike) -- this was never wio-specific.
- The checkpoint/delta compression idea raised alongside this question
  (real numbers: ~23-25% smaller, at the cost of giving up single-call
  `std::lower_bound` for a two-level checkpoint+linear-scan lookup) remains
  unimplemented -- a real, smaller, riskier win than this ADR's fix, not
  pursued here.
