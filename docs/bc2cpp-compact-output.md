# Compact generated C++

Set `BC2CPP_COMPACT_OUTPUT=1` when running `tools/bc2cpp/bc2cpp.rb` to remove
`//` diagnostic comments from its C++ output. Normal output remains the default:
many compiler checks inspect those comments for proof and dispatch markers.
Run those checks without this option.

The rewriter protects string, character and raw string literals, and keeps block
comments. It preserves newlines, so compiler line numbers stay stable. C++ code,
preprocessor directives, generated declaration headers and stderr reports remain
unchanged. This reduces generated source size and output I/O; it does not reduce
the executable's code or claim a native compilation speedup.

Compact mode buffers the generated translation unit before rewriting it, so it
uses extra memory proportional to source size. Enable it only when that tradeoff
is useful. The standalone regression check is
`ruby scripts/bc2cpp/compact_output_check.rb`.

A full rpg2k translation-unit sample shrank from 19,695,404 to 14,307,521
bytes (27.4%) in a 0.093-second local YJIT rewrite. Both versions retained
386,389 newlines and produced byte-identical `c++ -E -P` output. These are
source-size measurements, not native compile-time or executable-size results.
