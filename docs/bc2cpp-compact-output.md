# Compact generated C++

> **Historical record.** The `wio` build named here was removed; `closed` is its successor. Figures are as measured then.

`tools/bc2cpp/bc2cpp.rb` writes compact C++ by default (ADR 0463): the `//` diagnostic comments it attaches to every
call site and method are removed from its stdout. There is no environment switch. A caller that reads those comments
(the proof and dispatch markers the fixture checks match, `MONO :name -> ...`, `CLOSED_WORLD_SELF`, and so on) passes
`--annotated` on the command line; `Bc2cppFixtureRuntime.generate` and every check and tool that spawns the generator
and reads its stdout do so.

The generator still builds every comment while it compiles, because some of its own passes read them (for example the
`CLOSED_WORLD_SELF` count and the runtime-def offender scan); only the emitted text is compacted. The stderr reports
are unchanged: they are the machine-read channel (NOMETHOD, STRICT_HINT_SITE, the compiled entry points, the type
facts) and cost about 0.1 s to build on the whole engine.

Three comment kinds stay in compact output, one structural line per generated function, because
`scripts/bc2cpp/hot_profile.rb` reads them from a build's `*_gen.cpp` to map callgrind functions to Ruby methods:

* `// Owner#name (compiled from irep N, M insns)`, the method header;
* `// Owner#ivar -- synthesized attr_reader override` (and `attr_writer`);
* `// KIND :name -> Owner#name (keyword call) ...`, a keyword call's required callee.

The rewriter protects string, character and raw string literals, and keeps block comments. It preserves newlines, so
compiler line numbers stay stable. C++ code, preprocessor directives and generated declaration headers are unchanged.

Compact mode buffers the generated translation unit before rewriting it, so it uses extra memory proportional to the
source size. The standalone regression check is `ruby scripts/bc2cpp/compact_output_check.rb`.

A full rpg2k translation-unit sample shrank from 19,695,404 to 14,307,521 bytes (27.4%) in a 0.093-second local YJIT
rewrite; the whole wio shipped pass went from 21,014,948 to 15,616,317 bytes with the same code. Both versions keep
every newline and give byte-identical `c++ -E -P` output.
