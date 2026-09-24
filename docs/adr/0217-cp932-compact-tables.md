# 217. Compact CP932 tables; wio encodes without a reverse table

Date: 2026-09-23

## Status

Accepted. Amends [ADR 0111](0111-cp932-reverse-table-buildtime.md): wio no
longer carries the build-time reverse table that ADR introduced.

## Context

`mruby-lcf/cp932_to_unicode.rb` turns the WCTABLE section of Microsoft's
`bestfit932.txt` (9,486 Unicode -> CP932 best-fit pairs) into the tables
behind `LCF.cp932_to_utf8` and `LCF.utf8_to_cp932`. Since ADR 0111 these were
two `std::pair<uint16_t, uint16_t>` arrays, one sorted by CP932 code for
decoding and one sorted by Unicode for encoding, each read by
`std::lower_bound`. They are 37,944 B each, and together 75,896 B of the Wio
Terminal's 507,904 B flash. That makes `cp932.o` the largest single object
in the `wio_rgss_boot` link, and the firmware already overflows by about
624 KB.

Decoding runs whenever LCF data is read. Encoding only runs when strings are
written back as CP932, which in the engine means saving (`lcf.rb`'s
`to_lcf`/`encode`).

These properties of the data make a smaller layout possible. The generator
now checks each of them and fails the build if one stops holding:

- WCTABLE maps each Unicode code point exactly once, and never maps U+FFFF.
- Best fit is many-to-one in the other direction: 84 pairs share a CP932
  code with another pair, for example U+00C0..U+00C5 all encode to `A`. For
  those codes, ADR 0111's forward table returned the smallest code point.
- Every double-byte code has a lead byte in 0x81..0xfc. Each lead byte's
  trail bytes, first to last mapped, leave only 216 unmapped slots across
  the table.
- The user-defined area, lead bytes 0xf0..0xf9, maps linearly onto
  U+E000..U+E757. That is 1,880 entries.

## Decision

The generator emits these tables for every target:

- `cp932_single[256]`: single-byte codes. 0xFFFF marks an unmapped byte.
- `cp932_rows[124]`: one `{first_trail, last_trail, offset}` row per lead
  byte from 0x81 to 0xfc.
- `cp932_double`: the rows' trail ranges, stored densely as `uint16_t`
  Unicode values. There are 7,542 slots.
- `cp932_encode_extra`: the 84 best-fit pairs that decoding never returns,
  as `{unicode, cp932}` pairs sorted by Unicode.

The user-defined area is computed, not stored.

`mruby-lcf/src/cp932_lookup.hxx` reads them:

- **`cp932_decode`** is O(1) on every target. It picks the table by lead
  byte, and an out-of-range trail byte or 0xFFFF means unmapped.
- **`cp932_encode`** depends on the target:
  - **Desktop and other targets** keep ADR 0111's reverse table and binary
    search it, so encoding speed there is unchanged.
  - **wio** defines `CP932_NO_REVERSE_TABLE`. It is set in the generated
    `cp932.h` whenever `WIO_TERMINAL` is defined. The lookup binary searches
    `cp932_encode_extra`, computes the user-defined area, and otherwise
    scans `cp932_single` and `cp932_double`. Because every code point maps
    once, the first match found is the only one.

The generated arrays carry no per-entry comments any more. ADR 0111's
backslash-splice bug can no longer occur.

### Proof of identical behaviour

`scripts/cp932_tables_check.rb` is part of the CI `ruby-checks` job. It
builds a host harness and compares the new lookups with ADR 0111's lookups
(its `find_utf8`/`find_cp932` lambdas, verbatim) over ADR 0111's tables, for
all 65,536 inputs in each direction. It checks both encode configurations.
Both reference sources gave 0 mismatches:

- the reproduced ADR 0111 generator, which is the default;
- the historical generator itself: `git show
  7ed1848e:mruby-lcf/cp932_to_unicode.rb > old.rb`, then
  `--reference-generator old.rb`.

The results: 9,402 decodable codes and 9,486 encodable code points.

`lcf.cxx`'s transcoding loops are unchanged apart from calling these two
functions. `mruby-lcf/test/lcf_test.rb` pins the real transcoders on
single-byte, user-defined-area and best-fit inputs.

Two deliberate mutations both fail the check:

- taking the largest code point for shared codes: 40 decode mismatches;
- an off-by-one at the 0x7f trail gap in the user-defined area.

## Consequences

### Flash on wio

Per object, `arm-none-eabi-g++` 14.2.1 with the wio cross-build flags:

| object | ADR 0111 | this ADR |
| --- | ---: | ---: |
| `cp932.o` | 75,896 | 16,428 |
| `lcf.o` (the lookups are now two out-of-line functions) | 3,628 | 4,004 |
| total | 79,524 | 20,432 (−59,092) |

A full `wio_rgss_boot` link (the baseline configuration of
`scripts/wio_bc2cpp_measure.bash`) confirms it:

| link | flash (text+extab+exidx) | `FLASH` overflow | static RAM |
| --- | ---: | ---: | ---: |
| before (7ed1848e) | 1,132,068 | 624,164 | 32,296 |
| this ADR | 1,072,980 | 565,076 | 32,296 |
| change | −59,088 | −59,088 | 0 |

### Speed

Host figures come from `cp932_tables_check.rb` (x86-64, `-O2`):

- **Decode** falls from about 50 ns to about 9 ns per code on every target,
  because a direct index replaces a binary search.
- **Encode on desktop** is unchanged at about 50 ns per character.
- **Encode on wio** costs about 0.86 µs per non-ASCII character on the host,
  against about 0.05 µs before. On the SAMD51 at 120 MHz, the scan of about
  7,800 `uint16_t` slots is estimated at a few hundred µs worst case per
  non-ASCII character. That is tens of ms for a save's few hundred such
  characters, and it is paid only when saving.

### Desktop and other targets

They save 21,516 B of table data (37,944 B forward table → 16,428 B compact
tables), and decoding is faster. Their encode path is ADR 0111's.

### Follow-ups

A new `bestfit932.txt` that breaks one of the checked properties fails the
build loudly. The generator names the property, so the layout can be
revisited then.
