# Native-source scan allocations in NativeExpressionDevirt

`NativeExpressionDevirt` reads the mruby and gem C sources to find ROM method
tables (`rom_entries`), native method bodies (`scan_exact_class_expressions`,
`scan_analyze`) and registration macro calls (`macro_calls`). An object-mode
profile of the sealed Optcarrot compile attributed about 6.5% of allocation
samples to `String#scan` reached through `Enumerator#each` from those three
methods.

## Where the objects came from

The regex scans themselves were not the cost. Each match handed its position to
one of two hand-written Ruby scanners for C text: `brace_body` (find the
closing `}` of a function or table body, skipping comments and literals) and
`split_call_arguments` (split a macro call's arguments at top-level commas).
Both walked the source with `scanned[index]`, which allocates a new
one-character String for every character read; `brace_body` also read
`scanned[index + 1]`, so two Strings per character. A ROM table or a function
body is thousands of characters, and the table scan in `rom_entries` walks every
table in every native source to find its end. In an object-mode profile on
master, 11,036 of 152,851 allocation samples (7.2%) were under
`Enumerator#each` from these methods, and 9,596 of those were allocated
directly in `brace_body` (6,550) and `split_call_arguments` (3,046), almost all
at the per-character reads.

The `to_enum(:scan, pattern).each` form added one Enumerator per call on top of
that; the MatchData and capture Strings per match are needed by the callers and
stay.

## What changed

- `brace_body` and `split_call_arguments` read the ASCII view with `getbyte`
  and compare Integers against byte constants. `ascii_view` already replaces
  each non-ASCII character with one ASCII character, so byte indexes into the
  view equal character indexes into the source, and the returned slices are
  still taken from the real source with those indexes.
- The five `source.to_enum(:scan, pattern).each do ... end` loops are
  `source.scan(pattern) do ... end`. The block reads `Regexp.last_match`
  exactly as before; the scan position, order and return value of each loop are
  unchanged.

The scanned literals, the prefilters (`source.include?`, `scan_with`) and the
per-source caches are unchanged.

## Equivalence

The master version of `native_expression_devirt.rb` was loaded under another
module name next to the new one, and both were run over every valid-UTF-8
C/C++ source under `3rd/mruby`, `src`, `mruby-*` and `3rd/mruby-*` (238 files,
14 of them non-ASCII):

| Comparison | Cases | Mismatches |
| --- | ---: | ---: |
| `brace_body` from every `{` (including ones in comments and strings) | 16,764 | 0 |
| `split_call_arguments` from every `{` and `(` | 89,546 | 0 |
| `macro_calls` for 20 registration and other macro names per file | 4,760 | 0 |
| `rom_entries` per file | 238 | 0 |
| `scan_analyze`, `scan_class_registrations`, `scan_class_method_registrations`, `scan_exact_class_expressions` over all `.c` files | 4 | 0 |

The whole-world scans ran with `ScanCache` bypassed, so both versions computed
their results. The generated C++ of the sealed Optcarrot compile differs only
in the per-run temporary world path, as for any two runs of the same compiler.

## Measurements

Sealed Optcarrot compile, `scripts/bc2cpp/compiler_profile.rb --mode none
--optcarrot` (Ruby 4.0.5 with YJIT), one warm-up run and then three
alternating runs per version on the same host:

| Run | Version | `allocated_objects` | `elapsed_seconds` |
| --- | --- | ---: | ---: |
| 1 | master | 15,288,053 | 9.161 |
| 1 | this change | 14,252,917 | 9.292 |
| 2 | master | 15,287,964 | 10.076 |
| 2 | this change | 14,253,006 | 9.219 |
| 3 | master | 15,287,864 | 9.262 |
| 3 | this change | 14,253,310 | 10.120 |

Allocations fell by about 1,034,900 objects per run (6.8%), with a spread of
under 400 objects within each version. In the object-mode profile after the
change, `brace_body` has 26 total samples (was 7,534), `rom_entries` 384 (was
6,235), `scan_exact_class_expressions` 927 (was 5,621) and `macro_calls` 363
(was 1,471); what remains is mostly the argument Strings and regex captures
the callers keep.

`--optcarrot` builds a new temporary world per run, and these scans ran in
every run of both versions rather than coming from the scan cache (see
[compiler data profiling](bc2cpp-compiler-data-profile.md)). The allocation
count is the figure this change targets; elapsed time moved in both directions
between runs and shows no consistent change, so no speedup is claimed.
