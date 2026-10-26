# LCF schema-mask predicates

LCF row-flow kinds retain both their single-bit class mask and its Integer bit
position. Model lookups and final Array1D key checks test `mask[position] == 1`
instead of constructing a temporary large Integer intersection for every kind.
The full mask remains available for operations that need an actual union.

The kind table is fixed during model construction. Its foreign-class complements,
with and without nil, are computed there once and reused by index queries. Nil
handling, foreign-class contributions, field classes and exact-owner rules keep
their existing semantics.

On host Ruby 4.0.5, `Integer#anybits?` still allocates for wide operands. Single-bit
indexing avoids those allocations; using a predicate method name alone is not
sufficient. Multi-bit predicates still use the masks they require.

`lcf_row_flow_check.rb` compares the new model with the previous intersection
algorithm over mixed, empty, foreign, negative and wide receiver masks, both nil
policies, and several key types. Existing checks compare 1,511 schema reads with
the real reader and validate generated guards, refusals and runtime behavior.

## Whole-generator measurements

Two warm-cache comparisons on Ruby 4.0.5 + YJIT used the desktop closed
whole-engine source set, all compiled owners and hot-only disabled:

| Run | Baseline wall | Position-test wall | Baseline objects | Position-test objects |
| --- | ---: | ---: | ---: | ---: |
| 1 | 49.668 s | 49.328 s | 75,292,525 | 74,074,582 |
| 2 | 48.871 s | 48.518 s | 75,292,584 | 74,074,581 |

About 1.22 million allocations are removed per generation (1.62%); elapsed time
fell by about 0.7% in both local shared-host comparisons. Generated C++ and
diagnostics match after normalizing checkout paths and stripping diagnostic
timing lines, and workload input hashes match. Warmups were excluded. The
baseline is commit `8d7a15765`, before the separate inline-scope byte scan.
These measurements exclude C++ compilation and game runtime.
