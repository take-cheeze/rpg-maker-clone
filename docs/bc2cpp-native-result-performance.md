# Native-result proof performance

Native-result inference asks which registered class a receiver mask can hold
and joins the native return facts for those classes. The generator now reuses
an immutable snapshot of class/bit/position entries and tests individual bits
without constructing temporary bignum intersections.

A snapshot is rebuilt when the class table grows or is replaced. A query
retains the snapshot it started with, so a class discovered by a return proof
is visible on the next query. Native return facts, class-bit allocation order
and generated guards retain their existing behavior. See
[ADR 0489](adr/0489-bc2cpp-native-result-class-snapshots.md) for the invariants.

Measurements use the Nix flake's Ruby 4.0.5 with YJIT, the Wio whole-engine
source set, all compiled-gem owners, `SKIP_UNSUPPORTED=1`,
`BC2CPP_HOT_ONLY=0` and no `BC2CPP_HOT_METHODS` list. This measures host-side
bc2cpp generation, excluding base-RBS regeneration and C++ compilation.

Two alternating warm-cache comparisons against baseline `2f78735b` on the
same shared host measured:

| Run | Wall time | Allocated Ruby objects | GC time |
| --- | ---: | ---: | ---: |
| Baseline 1 | 41.35 s | 107.74 million | 9.62 s |
| Optimized 1 | 39.62 s | 82.78 million | 8.61 s |
| Baseline 2 | 41.53 s | 107.74 million | 10.02 s |
| Optimized 2 | 40.55 s | 82.78 million | 9.53 s |

This removes about 25 million allocations per pass (23.2%) and reduced wall
time by 2.4–4.2% in these runs. Warmups were excluded. All generated C++ was
byte-identical (20,909,643 bytes), as were diagnostics after removing timing
lines and normalizing checkout paths. Ten generated-code fixtures also
produced byte-identical output against the baseline. These are local generator
measurements, not game runtime or complete build timings.

`scripts/bc2cpp/native_result_facts_check.rb` exercises the native source
audits, receiver snapshot behavior, randomized equivalence against the
previous query algorithm and generated-code fixtures when `MRBC` is set.
