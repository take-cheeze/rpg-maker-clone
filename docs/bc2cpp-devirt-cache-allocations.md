# Per-file devirt scan entries and the LOADI dispatch test

Two allocation sources in the sealed Optcarrot compile, measured on master
`8b208c5cc` (before #3103 and #3105 merged; see the end of Measurements for
the merged master):

- `NativeExpressionDevirt` rescanned the native C sources on every compile
  of a temporary world (`compiler_profile.rb --optcarrot`), even when the
  scan cache was warm.
- `CodeGen#compile_insn_op` tested every opcode after `LOADSYM` against
  `/^LOADI/`, and each test allocated a MatchData.

## Why the devirt scans ran warm

`analyze`, `analyze_exact_class_expressions`, `class_registrations` and
`class_method_registrations` each have one `ScanCache` entry keyed by the
whole path list. A temp-dir world copies `main.cxx` and
`mruby_onig_regexp.c` into a new directory on every run, so every whole-list
entry missed. Every file was scanned again: 103 paths for `analyze` and the
exact-class scan, then the 103-, 51- and 20-path `class_registrations` lists,
and the 51-path class-method list. `path_registrations` also rescanned about
20 single sources per process, because its memo lives only in memory. In an
object-mode profile, these scans had about 2,250 of 62,115 samples (3.6%),
mostly in `rom_entries`, `split_call_arguments` (and its `String#strip`),
`macro_calls` and `symbol_name`.

## What changed

The whole-list entries stay in front, so a fixed-path build that hits them
does the same work as before. When they miss, each scan merges per-file
entries (`DEVIRT_FILE_CACHE`) in path order:

| Entry | Inputs | Value |
| --- | --- | --- |
| `native_expression_devirt.class_registrations.file` | one source | that file's `[registrations, opaque_owners]` pairs |
| `native_expression_devirt.analyze.file` | one source | that file's whole-receiver registration pairs |
| `native_expression_devirt.analyze.bodies.<needed>` | one source | `[function, expression]` for that file's bodies of needed functions |
| `native_expression_devirt.exact_class.bodies.<needs>` | one source + the public API headers | `[function, arity, expression]` for that file |
| `native_expression_devirt.class_method_registrations.file` | one source | that file's class-method registration pairs |

Every per-file entry uses `cache_absent: false`. The callers skip paths that
are not files, as before. `scan_class_method_registrations` never checked,
so a missing path still raises from `read_source`. `path_registrations` and
`codegen_frozen_tables.rb` call `scan_class_registrations`, so they read the
same entries.

### Cache-key soundness

`ScanCache` keys every entry with the scan name, the digest of every
`tools/bc2cpp` source, the Ruby and Marshal versions, and each input path
with its SHA-256. A per-file entry is sound if its value depends only on the
file's text and on facts named by the entry name.

- **Registrations.** `scan_file_class_registrations` reads only its source:
  `class_variable_map(source)`, the file's `MRB_SET_INSTANCE_TT` tags and
  `MRB_MT_INIT_ROM` owners, `rom_entries(source)` and `macro_calls`. Each
  table owner is resolved inside that file. `symbol_name`, `safe_arity` and
  `unescape_c_string` are pure functions of their arguments, and
  `BUILTIN_CLASS_TAGS` is part of the tools digest. The analyze and
  class-method registration parts have the same shape.
- **Analyze bodies.** The old loop read a file's function bodies only for
  `needed`: the functions registered so far, including this file. That set
  grows file by file. The loop asks `needed.include?(function)` only for a
  `\w+` capture, so the members that match `\A\w+\z` are all that matter.
  Their sorted digest is part of the entry name. An empty set means no
  bodies, so it is not stored.
- **Exact-class bodies.** A file's expressions depend on its text, on the
  set of `[function, arity]` pairs needed by every file's registrations, on
  the mruby root (the `3rd/mruby` prefix test and the `File.join` text), and
  on `public_mrb_value_functions`, which reads the public API headers. The
  sorted pairs and the root name the entry, and the headers are inputs.
  Each pair collects its own expressions, so the order of the pairs does not
  change the result, and a reordered list reuses the entries.

### Order

Merging per-file Hashes in path order inserts each name where one pass over
all files would. A name keeps the place of its first file, and its entries
follow file order and then source order. The analyze bodies are merged the
same way. The exact-class lists are appended per `[function, arity]`, which
is the only way they are read. The default procs of the merged maps are
restored as before (`Hash.new { ... }`, then `concat`).

## The LOADI dispatch test

`case insn.op ... when /^LOADI/` calls `Regexp#===` for every opcode that
reaches that `when`. On Ruby 4.0.5, a Symbol test allocates one object when
it misses and two (with the MatchData) when it matches. The sampled profile
attributed 547 samples to it. The branch is now `when LOADI_PREFIX`, a lambda
that tests `op.is_a?(Symbol) && op.start_with?('LOADI')` and allocates
nothing. Ops are Symbols, because `Insn#op=` and `Insn.new` intern a String
op. An opcode name has no newline, so `^` could only match at the start. No
branch of `compile_insn_op` reads `$~`, `$1` or `Regexp.last_match`, so the
missing MatchData is not observable.

## Equivalence

Generated C++ from every run below matched master byte for byte, after
normalizing the temporary world path in both its plain form and its
`\x..`-escaped string literal. The fixed-path runs matched with no
normalization.

A comparison script loaded master's `native_expression_devirt.rb` as a
second module. It compared master's `scan_class_registrations`,
`scan_analyze`, `scan_exact_class_expressions` and
`scan_class_method_registrations` with the new ones by `inspect`, which
shows every key and element in order, and by a recursive `to_a`:

| Lists | Cache off | Cold | Warm (per-file only) |
| --- | --- | --- | --- |
| the 84 core sources | equal | equal | equal |
| all 243 C/C++ sources under `3rd/mruby`, `src`, `mruby-*`, `3rd/mruby-*` | equal | equal | equal |
| the core sources reversed | equal | equal | equal |
| core sources plus five copies in a new directory and one missing path | equal | equal | equal |
| each of the 243 files alone | equal | equal | equal |

None of the warm runs called a per-file scan. The merged maps kept their
default procs.

`scripts/bc2cpp/scan_cache_check.rb` now checks the following. Each scan
stores one entry per file. A list with one more file scans only that file.
A reordered list of stored files, which misses every whole-list entry,
rescans no file. Both results equal the scans with the cache off.

## Measurements

Ruby 4.0.5, mrbc built from pinned mruby, `compiler_profile.rb --mode none`.
Each version ran once to warm up, then three runs of each were alternated.
Base is `8b208c5cc`.

**`--optcarrot`, warm.** Every run has a new temporary world:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6,214,378 | 5,996,634 | 6.829 | 6.602 |
| 2 | 6,214,369 | 5,996,631 | 7.071 | 6.639 |
| 3 | 6,214,379 | 5,996,560 | 7.230 | 6.688 |

That is 217,750 fewer allocations (3.5%). With `codegen_insn.rb` reverted,
the devirt entries alone gave 6,051,030 and 6,050,745: 163,500 fewer (2.6%).
The LOADI test accounts for the other 54,300 (0.9%). In the object profile,
the devirt scans fell from about 2,250 samples to 614. What remains is mostly
`ScanCache.fetch` loading the per-file entries, plus the three new temp files.
`Regexp#===` under `compile_insn_op` fell from 547 samples to none.

**`--optcarrot`, cold.** `build/bc2cpp-cache` was deleted before each run:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 7,753,163 | 7,661,133 | 7.886 | 7.686 |
| 2 | 7,753,258 | 7,661,272 | 7.976 | 7.882 |
| 3 | 7,753,200 | 7,661,013 | 8.292 | 7.966 |

That is 92,100 fewer (1.2%). The LOADI test saves about 54,500. The devirt
change saves about 37,600 (one devirt-only cold run: 7,715,611), because the
51- and 20-path lists and `path_registrations` load the entries that the
103-path scan has just stored. In return, a cold compile writes 414 small
per-file entries, and each later temp-world run adds 9 more for its new paths.

**Fixed path, warm.** The same world is rebuilt at one path for every run,
so the whole-list entries hit:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 5,836,936 | 5,780,303 | 6.885 | 6.647 |
| 2 | 5,837,100 | 5,780,286 | 6.627 | 6.582 |
| 3 | 5,837,146 | 5,780,300 | 6.999 | 6.712 |

That is 56,700 fewer (1.0%), all from the LOADI test: the per-file entries
are not read on this path.

**After #3103 and #3105.** The branch was merged with master `82b93ceff` and
measured again with `--optcarrot`, warm:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 5,241,383 | 5,061,396 | 7.159 | 6.904 |
| 2 | 5,241,317 | 5,061,514 | 7.804 | 6.282 |
| 3 | 5,241,309 | 5,061,399 | 6.762 | 6.839 |

That is 179,900 fewer (3.4%). The cold warm-up runs were 6,779,105 before
and 6,705,915 after (1.1% fewer).

Timings were taken on a shared machine. They do not establish a speedup.

## Not changed

`UniqueClassNames.native_bindings` and `ConstBindings.native_class_owners`
still call `split_call_arguments` from `to_enum(:scan)` (about 90 samples).
Their results hold the source String and offsets, so they are not plain data
for the scan cache.
