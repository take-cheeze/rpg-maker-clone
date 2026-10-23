# Native base RBS scanning

The native base RBS generator scans preprocessed C/C++ to associate method
registrations with owners, argument formats and return kinds. It also uses
Clang AST analysis for return inference.

Function-body extraction jumps directly between brace matches rather than
visiting every character. It retains the existing textual brace counting,
including its treatment of braces inside strings and comments. Match offsets
and slices both use Ruby character offsets, so Unicode before or inside a
body preserves the extracted text. Unterminated bodies still return an empty
string.

The core-owner assignment pattern starts only at the beginning of a complete
word. A successful full-word match already wins before any suffix of that
word, so this removes redundant regex attempts without changing captures.

## Measurement

A local CRuby 3.4.9 (historical; the bc2cpp jobs now use Ruby 4.0.5) comparison scanned the same 49 successfully preprocessed
native files (32,008,444 bytes) three times per implementation. Baseline times
were 4.85, 5.05 and 5.04 seconds; optimized times were 1.92, 2.01 and 2.00
seconds. Marshalled scan-result SHA-256 hashes matched on every run. This
isolates textual scanning, with no AST-return table installed, and excludes
Clang execution and JSON parsing.

Two alternating full serial generations took 34.98/35.34 seconds on the
baseline and 32.03/31.89 seconds with this optimization (about 9% less wall
time). All 71 generated RBS files and stderr diagnostics were byte-identical;
report rows matched after normalizing output-directory paths. These timings
isolate this change from the separate native-file worker-pool improvement.

The source set used existing host build headers. Two gems could not
preprocess because `oniguruma.h` and `io_hal.h` were unavailable. This is not
a complete-build or game-runtime measurement.

`scripts/bc2cpp/base_rbs_check.rb` checks nested and adjacent functions,
Unicode offsets, missing/prototype/nonidentifier functions, unterminated and
long bodies, randomized equivalence with the previous brace walk and
assignment pattern, and registration-to-owner integration.
