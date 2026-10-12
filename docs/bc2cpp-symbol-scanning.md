# bc2cpp symbol scanning

The symbol-cache pass rewrites generated C++ calls with literal names and
records the referenced symbol slots. It matches argument patterns at their
exact offsets in the original buffer, avoiding a suffix string per match.
Its ASCII grammar scans byte offsets, then restores the input encoding for
rewritten output and symbol literals. Nested calls retain their original
slot ordering, and nonliteral names remain untouched.

The scan patterns are compiled once. This also avoids repeated UTF-8 character
offset conversion when scanning long generated functions.

A local CRuby 3.4.9/YJIT benchmark of 50,000 flat calls took 2.22 seconds for
rewriting and 0.97 seconds for slot collection before this change, versus
0.14 and 0.06 seconds afterward. Output hashes matched. Full-source rpg2k
generation improved from 12.51/12.47 seconds to 12.20/12.10 seconds in an
alternating comparison, with byte-identical C++. The larger scanner gain is
specific to long buffers and does not describe total CI time.

`scripts/bc2cpp/symbol_cache_check.rb` covers nested calls, Unicode names and
prefixes, rejected nonliteral arguments, a large flat buffer and the generated
cache's behavior across VMs.
