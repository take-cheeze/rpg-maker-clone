# 0416. bc2cpp: one Prism parse per foreign Ruby text per process

Date: 2026-10-12

## Status

Accepted

## Context

The whole-engine generator pass (`scripts/bc2cpp/coverage_report.rb`) parses every foreign Ruby source it scans
with `Prism`. Two consumers do this:

* `foreign_method_names` (`tools/bc2cpp/native_names.rb`) parses each path it is given. `ClosedWorld#outside_ruby_paths_defining`
  calls it once per method name with a one-path list, so each mrblib file was parsed once per name: 143,530 `Prism.parse`
  calls in one generator pass over the engine.
* `ForeignDefiners.scan_files` (`tools/bc2cpp/foreign_definers.rb`) parses the same files again, and its one-entry cache
  is cleared whenever the path set changes.

Each call produces the same tree, because the text is the same.

## Decision

Add `tools/bc2cpp/ruby_parse_cache.rb` (`RubyParseCache`). It keeps one entry per path: the exact bytes it was parsed
from and the `Prism.parse` result. A lookup hits only when the stored bytes are equal to the requested bytes, so different
text never receives another text's tree, and a rewritten file replaces its entry rather than growing the cache. Both
consumers call it; neither now calls `Prism.parse` or `Prism.parse_file` directly.

The bytes are compared, not the Ruby string's encoding. Prism parses the bytes and ignores the encoding of the string it was
given; `scripts/bc2cpp/ruby_parse_cache_check.rb` checks this on the real foreign mrblib files and on random texts with invalid
UTF-8.

Trees are shared unfrozen. Prism 1.5 memoizes `Node#location` on first use, so a frozen node raises on that read (the check
caught this when the nodes were frozen). Instead the two consumers only visit the tree and never write to it, which the
check exercises. A consumer that needed to write would have to parse its own copy.

## Consequences

On the whole-engine pass, `Prism.parse` calls go from 143,530 to 152 (one per distinct foreign text plus the few other
parses), and the generated C++ (`shipped.cxx`, 20,011,694 bytes), the stderr diagnostics and the coverage report are
byte-identical.

Timing: the parse work removed is about 40 s of CPU per pass (one timed parse of each of the 76 files, times the 143,530 baseline
calls, less one parse per file), against an 825 s baseline pass: about 5%. The wall-clock A/B could not resolve it, because the
machine was shared (load average 5 to 24 on 4 cores): the baseline ran at 825 s and 1,011 s, the patched tree at 1,068 s. The
per-name scan still runs its regexes once per name, so the saving is the parse share only.

`scripts/bc2cpp/ruby_parse_cache_check.rb` (in `ruby-checks`, and in `scripts/coverage/report.rb` CHECKS) covers the
equivalence of the three read paths, random texts, hit, miss and rewrite behavior, the caller's text staying unfrozen,
the consumers against an uncached walk, and one parse per text per scan.
