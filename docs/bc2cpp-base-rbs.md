# Base RBS generation

Generate Ruby and native base declarations for all repository gems with:

```sh
ruby scripts/bc2cpp/base_rbs_all.rb --jobs 2 OUT_DIR CLOSED_BUILD_DIR
```

`CLOSED_BUILD_DIR` supplies generated mruby headers. The output is base stubs
under `OUT_DIR`, separate from the checked-in signature inputs. Native files
need Clang and the headers their gems include. A gem that cannot preprocess
is listed as `native failed` in the report; AST-analysis failures retain the
existing logged fallback to regex return analysis.

Native files use up to two worker processes by default, limited to one on a
single-processor host. `--jobs N` (or `-j N`) sets the limit; `--jobs 1` runs
serially. Ruby implementations without fork support also run serially.
The per-gem generator accepts the same option:

```sh
ruby scripts/bc2cpp/base_rbs_native.rb --jobs 2 OUT_DIR -I INCLUDE_DIR SOURCE.cxx
```

Each worker preprocesses and scans one source. It runs Clang AST extraction
and parses the JSON only if a registered function has a body whose return kind
needs analysis. Files with only class registrations, external function
registrations, or no registrations skip that work. Each file loads its AST at
most once; same-file helper functions remain available to the return analysis.
Preprocessing failures retain their error report without a redundant AST warning.
The parent merges
results and diagnostics in source order, preserving declaration precedence
and skipped registrations. Increasing jobs can reduce wall time but permits
more large Clang ASTs in memory simultaneously. See [ADR 0488](adr/0488-base-rbs-native-file-workers.md).

## Local measurement

Two alternating comparisons took 36.9/37.4 seconds on the baseline and
27.1/26.6 seconds with two workers (26–29% less wall time). All 71 generated
`.rbs` files and stderr diagnostics were byte-identical; report rows matched
after normalizing output-directory paths.
This comparison used CRuby 3.4.9, Clang 21.1.8 and the existing host build's
headers. It excluded two native gems that failed preprocessing because
`oniguruma.h` and `io_hal.h` were unavailable in that environment. These are
base-generation timings, not bc2cpp compilation or game runtime timings.

Run `ruby scripts/bc2cpp/base_rbs_check.rb` to check scheduling, error handling
and serial/parallel output equivalence. Its native fixture requires Clang.

A later lazy-AST comparison on CRuby 4.0.5 + YJIT and Clang 21.1.8 took
21.12/21.45 seconds before this change and 13.33/12.28 seconds after it
(37–43% less wall time), with two workers. AST extractions fell from 51 to 17.
All 71 generated RBS files were byte-identical and the normalized report rows
matched. The same two missing-header native gems were excluded as above.
