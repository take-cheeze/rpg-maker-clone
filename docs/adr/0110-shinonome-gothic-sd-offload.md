# 110. Move the Shinonome GOTHIC (kanji) face to the SD card

Date: 2026-09-09

## Status

Accepted

## Context

The per-component flash breakdown done earlier this session found the
embedded Shinonome JIS0208 kanji face (`shinonome::GOTHIC`) is 165,624
bytes -- confirmed *live* in the real linked image (one contiguous
165,624-byte allocated section), bigger than mruby-rgss's entire engine
logic (`lib.cxx`, 126,046 bytes) by itself. ADR 105 already added an opt-in
subsetting mechanism (`SHINONOME_GLYPH_TEXT_FILE`) for it, but nothing
wires a real corpus in by default, and even a subset still ships whatever
kanji *are* selected in flash.

ADR 108 already tried moving a much bigger flash cost -- mruby-rpg2k's
compiled Ruby -- to the SD card, and found the mechanism (`mrb_load_irep_buf`)
works but its RAM cost scales with total bytecode size (ADR 99's own
finding), which ruled that attempt out. The font face is a fundamentally
different shape of data: `find_char` (mruby-rgss/src/lib.cxx) already
`std::lower_bound`s a **sorted, fixed-record-size array** -- no interpreter,
no IREP, nothing whose memory cost scales with how much of the table is
resident. That is exactly the shape a plain binary-search-over-a-file
replaces with no new memory-scaling risk at all.

## Decision

**`gen_shinonome_data.rb`** gained a second, independent opt-in escape
hatch, `SHINONOME_GOTHIC_SD_FILE` (a no-op unless set, same convention as
`SHINONOME_GLYPH_TEXT_FILE`): when set, every glyph the GOTHIC pass would
have written into the compiled-in C array instead goes to a flat packed
binary file -- `u32 glyph_count`, then `glyph_count *` (`u32 codepoint`,
5 `* u32` bitmap words), little-endian, still sorted by codepoint (a
record is byte-for-byte `sizeof(shinonome::Char<HEIGHT>)`, module its
`char32_t` vs `uint32_t` naming). `shinonome.cxx`'s own `GOTHIC` array is
still emitted, just empty (`GOTHIC_LEN` 0), so a build that sets this
without also wiring the read-back path below simply finds no kanji glyphs,
rather than failing to compile.

**`mruby-rgss/src/lib.cxx`** gained `find_gothic_char(c)`, which every real
call site (`measure_text`, `bmp_draw_text`, `bmp_blend_text`'s two
variants) now goes through instead of calling `find_char(c, shinonome::
GOTHIC, ...)` directly: checks the (possibly-empty) compiled-in array
first, and only when `RGSS_SHINONOME_GOTHIC_SD_PATH` is defined (a build-
time macro naming the on-device path, `mruby-rgss/mrbgem.rake`'s own new
escape hatch) falls through to a small binary-search-over-`std::fopen`
reader. This reuses the *exact same* file API `bmp_init_file` already uses
for every game asset on every target including wio -- no new HAL, no new
platform-specific I/O path. A fixed 64-slot round-robin cache (`sizeof
(Char<HEIGHT>)` = 24 bytes/slot, 1,536 bytes of static BSS total) keeps
every glyph a session has already drawn resident, so an ordinary dialogue
box that reuses the same few dozen kanji repeatedly touches the SD card
once per *distinct* glyph, not once per character drawn.

### What was verified

**Data-level**: `SHINONOME_GOTHIC_SD_FILE`'s own 165,100-byte output,
parsed back and compared entry-by-entry against the compiled-in array a
plain (non-SD) generator run produces from the same source data -- all
6,879 glyphs, exact match, correct sort order, no missing or extra entries.

**Code-level, on the host**: a standalone test links the *exact* `find_char`
+ `Cache` + `find_gothic_char` code added to lib.cxx (copied verbatim, not
reimplemented) against the real generated file, built with `GOTHIC_LEN == 0`
(so every lookup is forced through the SD path, never silently satisfied by
a compiled-in fallback) and checks 149 codepoints (the first 50, last 50,
and an even spread across all 6,879) against the reference array -- exact
bitmap match on every one, a clean miss on a codepoint guaranteed outside
any real table, and a second pass re-reading already-cached codepoints to
exercise the cache-hit path specifically. All pass.

**Real relink**, `env:wio_rgss_boot`, on top of ADR 109's own state:

| state | FLASH overflow | RAM |
| --- | --- | --- |
| ADR 109 (schema blob) | 1,260,564 | fits |
| + GOTHIC SD offload (256-slot cache) | 1,095,820 | **overflows by 248** |
| + GOTHIC SD offload (64-slot cache) | 1,095,748 | fits |

**164,816 bytes of flash recovered** -- essentially the whole GOTHIC face,
minus the small new lookup/cache code. The 256-slot cache's own real RAM
overflow (248 bytes, caught by the same relink-and-check discipline this
whole series has used throughout) is why the shipped cache is 64 slots:
this board has no RAM margin to spend on an untested cache size, and 64
still covers a realistic dialogue box's own distinct-kanji count with
plenty of headroom for eviction to be rare rather than constant.

Combined with ADR 109, both landed together: **1,276,188 → 1,095,748**,
180,440 bytes of this port's flash overflow recovered today.

### What was not done

- **No real (emulated) hardware test.** Per ADR 108's own established
  reasoning, a Renode SD-card boot run earns its cost once there is a real
  reason to doubt the *mechanism* -- here, the mechanism is exactly
  `std::fopen`/`fseek`/`fread`, already proven on real wio hardware by
  every existing asset load (`bmp_init_file`), and the *new* logic (the
  binary search and cache) is verified byte-for-byte on the host against
  the actual production code. What a hardware run would add is confirming
  real SD read *latency* is acceptable for on-screen text -- a genuine open
  question (see below), but a performance question, not a correctness one,
  and not worth a full Renode SD-image run to answer speculatively.
- **Latency is unmeasured.** Every cache miss costs `O(log 6879) ≈ 13`
  `fseek`+`fread` round trips (worst case, before the record's own data
  read) against a real SD card -- slow compared to reading a compiled-in
  array, and unlike a boot-time cost (ADR 108's rpg2k Ruby, one-shot), a
  cache miss can happen mid-frame while drawing dialogue. The 64-slot cache
  keeps *repeat* draws of the same glyph free, but the *first* frame of any
  screen with previously-unseen kanji pays every miss it introduces. No
  game data is loaded by this port's current boot firmware at all, so this
  could not be measured against a real play session here; if a future
  session gets real game data loading working, this is the first thing to
  profile.
- Neither `SHINONOME_GOTHIC_SD_FILE` nor `RGSS_SHINONOME_GOTHIC_SD_PATH` is
  wired into any real build's default flags -- both are no-ops unless set,
  the same convention as every other escape hatch this series has added.
  Shipping this for real still needs an actual SD-card deployment step that
  writes `gothic.bin` alongside a game's exported data, which does not
  exist yet (the same gap ADR 108 named for rpg2k's own SD-offload attempt).

## Consequences

- The single largest piece of static data this port carries is no longer
  in flash at all, for the wio build willing to opt in -- a much better
  trade than ADR 108's rpg2k attempt, since it costs no interpreter RAM
  overhead and needs no new I/O abstraction.
- Text rendering now has a real, if unmeasured, latency dependency on SD
  card speed for any kanji not already drawn this session. A future
  profiling pass (once real game data loading exists to test against) may
  find the 64-slot cache needs to grow, shrink, or become a true LRU rather
  than round-robin -- this ADR's own real numbers are the baseline to
  compare against, not a final answer.
- `HANKAKU`/`LATIN1` (halfwidth kana, Latin-1) are deliberately untouched:
  both are small, bounded charsets nearly every game's UI needs regardless
  of which kanji it uses, unlike JIS0208's much larger range -- the same
  reasoning `gen_shinonome_data.rb`'s own `SHINONOME_GLYPH_TEXT_FILE`
  comment already gives for never subsetting them.
