# Native signature marker reuse

Native signature membership is determined by `# bc2cpp-native: <table>` comments
in RBS declarations. A member's own marker wins; otherwise it takes the nearest
marked enclosing declaration. An untagged declaration can remain a program
hint beside tagged native members.

`NativeSigs.own_table` reuses the parsed marker for equal comment text, including
comments with no valid marker. It retains at most 4,096 entries per compiler
process. The real declaration file has 273 unique comment texts, so repeated
loaders no longer create a String and regex match for every marker lookup.
Cache saturation changes only reuse: uncached comments are still parsed.

Only the node's own marker is retained, never its inherited membership. The
same untagged member therefore remains valid under different enclosing chains.
RBS nodes and comment Strings can be mutable, even when a node itself is frozen.
Ruby Hash copies String keys into frozen snapshots; mutation or replacement of
a comment is looked up by its new contents. The cache retains no AST nodes.
Returned marker names are frozen so callers cannot alter a shared result.

The existing `native_member_tables_check.rb` covers ordinary and inherited
membership, member overrides, every real table's source round trip, mutable
comments, negative lookups and cache saturation.

## Focused allocation comparison

Run the benchmark with the same Ruby version and machine for both cases:

```sh
ruby scripts/bc2cpp/native_marker_bench.rb
ITERATIONS=30 ruby scripts/bc2cpp/native_marker_bench.rb
```

The reference reader uses the previous uncached marker parser; both readers
render all native table sources identically before measurement. The measured
work repeats selection of all 43 tables from the same already-parsed real RBS
AST. Both readers are warmed first and GC remains enabled.

One Ruby 4.0.5 run with 10 iterations allocated 16,777,409 objects using the
uncached reader and 4,727,942 using cached markers, a 71.8% reduction for this
signature-selection workload. Elapsed times were 2.53 s and 0.85 s. These are
focused measurements, not whole-compiler timing or peak-memory claims.
A native allocation-event counter attributed the removed allocations primarily
to Strings, MatchData and VM internal objects; Array creation in table
selection is unchanged.

## Whole-compiler allocation counts

A matched-path, warm sealed Optcarrot compilation on Ruby 4.0.5 compared
`db3ef7aef` with only this marker-cache change. A native `NEWOBJ` event counter
recorded every allocation while leaving GC enabled, including objects later
collected. Compiler loading, analysis and C++ emission were measured; preparing
the sealed workload was outside the measured region. Both versions used the
same pinned mrbc and source paths, and generated C++ was byte-for-byte identical.

| Allocation type | Before | After |
| --- | ---: | ---: |
| All objects | 11,267,812 | 10,932,271 |
| String | 3,728,728 | 3,561,307 |
| Array | 4,267,197 | 4,267,198 |

The measured whole-compiler reduction is 335,541 allocation events (2.98%),
including 167,421 fewer Strings. Array allocations are effectively unchanged.
These are object counts, not allocated bytes, retained memory or a demonstrated
compiler speedup. The larger percentage in the focused benchmark above applies
only to repeated native table selection.
