# Native identifier-token scan allocations

Several bc2cpp scans list every identifier in the native C/C++ sources, and
some foreign Ruby sources:

- `outside_world_tokens` (`tools/bc2cpp/native_names.rb`) finds the names
  code outside the closed world could call.
- `ClosedWorld.native_file_facts` (`tools/bc2cpp/closed_world.rb`) collects
  per-file code tokens, registrations and touches for the closed world.
- `NativeConstructorSigs.registered_body`
  (`tools/bc2cpp/native_constructor_sigs.rb`) audits the
  `rgss_constructors` table.

An object-mode profile of the sealed Optcarrot compile on master
(`f9b485c1b`, 93,876 samples) put 6.6% of allocation samples directly in
`String#scan`. Each match is a new String, so a scan allocates one object per
token occurrence, not per distinct name. The C/C++ sources under `3rd/mruby`,
`src`, `mruby-*` and `3rd/mruby-*` contain about 369,000 occurrences of
24,590 distinct tokens. Deduplicating while scanning does not help: in pure
Ruby, each match is still materialized before a Set can reject it.

## Why the scans ran at all

`ScanCache` already stores these scans on disk. Their whole-list entries,
however, are keyed by every input path. A world with even one new path misses
the entry and rescans every file. `compiler_profile.rb --optcarrot` and other
temp-dir builds copy `main.cxx`, `mruby_onig_regexp.c` and one Ruby source
into a new directory on every run. So `outside_world_tokens` (142 inputs) and
`closed_world.native` (103 inputs) rescanned the other 139 and 101 unchanged
files each time. `ScanCache.compute` covered 8,460 samples (9.0%), and the
two scans covered 3,004 and 2,913 of them.

## What changed

- **Per-file entries under the whole-list entries.**
  `outside_world_tokens` merges `outside_file_tokens(path)`, a
  `ScanCache.fetch('outside_world_tokens.file', [path])` per file.
  `ClosedWorld.native_facts` wraps each `native_file_facts(path)` in
  `ScanCache.fetch('closed_world.native_file', [path])`. Each per-file key
  covers the path and the file's digest, as the whole-list key does. When the
  whole-list entry misses, only new or changed files are rescanned. The
  whole-list entries stay in front, so a fixed-path build that hits them does
  the same work as before. The per-file `outside_world_tokens` scan keeps
  `cache_absent: false`, so a missing file is still reported and never
  stored.
- **Order.** Merging the per-file Sets in path order inserts each token
  where a single scan would: the first file that spells it, at the first
  place it appears there. `native_facts` was already a per-file `map`.
- **`registered_body`.** It ran `NativeOwnerMap.call_args` (one String per
  character) on each `mrb_define_method` call in a candidate file, for every
  `(class, name)` it looked up. `define_method_calls(text)` now splits each
  stripped text's calls once (`[open, args]`, at least four arguments, in text
  order). The lookup loop is otherwise unchanged. `class_vars` is still
  computed lazily, only after the first name match.

## Equivalence

Generated C++ from the before and after `--optcarrot` runs was
byte-for-byte identical, except for the per-run temporary world path, both
plain and hex-encoded. This held for every run below, both cold and warm.

A comparison script put master's implementations next to the new ones. It ran
them over all 243 C/C++ sources (`.c .cc .cpp .cxx .h .hh .hpp .hxx .inc`)
under `3rd/mruby`, `src`, `mruby-*` and `3rd/mruby-*`:

| Comparison | Result |
| --- | --- |
| `outside_world_tokens` with the cache off, cold and warm vs master's scan: element order, values and encodings | equal (24,590 tokens) |
| each `outside_file_tokens` vs master's scan of that one file | equal (243 files) |
| a reordered subset, and a list with a missing file | equal |
| `native_facts` with the cache off, cold, warm per-file and warm whole-list vs direct `native_file_facts` (`==`) | equal |
| computed `native_facts`, `Marshal.dump` | byte-identical to direct |
| warm entries, `Marshal.dump` | byte-identical to a Marshal round trip of the direct facts |
| `registered_body` vs master's loop, 14 classes × 149 registered names, over the 17 `mruby-rgss/src` sources | 2,086 pairs, 155 found, 0 mismatches |

Loaded entries are compared with a round trip because Marshal normalizes
object sharing, such as the same fstring in two fields. A warm whole-list
entry on master is also a round trip. Per-file entries share less across
files, never more.

`scripts/bc2cpp/scan_cache_check.rb` now checks that both scans store one
entry per file. It also checks that adding a file stores only that file's
entry, and that the union equals a single uncached scan.

## Measurements

Ruby 4.0.5, mrbc built from pinned mruby `93f276a8f`, `compiler_profile.rb
--mode none --optcarrot`. Each version was warmed first, then three runs of
each were alternated. Every `--optcarrot` run has a new temporary world, so
three inputs per run are new paths in both versions:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9,390,344 | 8,908,565 | 8.699 | 8.544 |
| 2 | 9,390,399 | 8,908,520 | 8.579 | 8.705 |
| 3 | 9,390,265 | 8,908,462 | 8.957 | 9.586 |

This removes about 481,800 allocations per compile (5.1%). In the object
profile, `outside_world_tokens` fell from 3,004 to 921 samples,
`native_facts` from 2,913 to 580, `registered_body` from 867 to 373, and
`String#scan`'s own samples from 6,168 to 1,772.

The cold case deleted `build/bc2cpp-cache` before each run:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9,554,585 | 9,517,323 | 9.215 | 10.573 |
| 2 | 9,554,821 | 9,517,420 | 9.667 | 9.769 |
| 3 | 9,554,685 | 9,517,542 | 9.844 | 12.429 |

When cold, both versions scan everything. The after version also writes 245
small per-file entries, and saves only the `registered_body` splits (about
37,000 allocations, 0.4%). Timings varied on a shared machine and do **not**
establish a speedup or a slowdown in either case.

A temp-dir world adds five per-file entries per run, a few tens of KiB in all.
Its whole-list entries already accumulated per run.
