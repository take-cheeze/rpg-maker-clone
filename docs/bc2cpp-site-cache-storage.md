# bc2cpp site cache storage

Class-narrowing result and subject caches use two-level tables: the outer Hash
selects an IREP by label, and the inner Hash selects an instruction by its Integer
index. This removes the temporary `[label, index]` Array formerly allocated for
every lookup and write. Tables stay private to each CodeGen instance.

A result cache distinguishes a missing entry from a cached nil with `key?`, so
unrecognized tests are computed only once. Different IREPs keep independent
entries at the same instruction index. Subject tables preserve register zero;
an ivar-only test overwrites any previous register subject with nil. No cache
invalidation or class-narrowing proof conditions change.

`scripts/bc2cpp/freeze_fold_check.rb` checks these cache semantics and guards
allocation-free warm cache hits. With MRBC, it verifies generated predicate
folding with its gate enabled and disabled.

A host Ruby 4.0.5 probe performed one million lookups of an already-cached nil
result in the actual `class_test_for` method, stubbing only the enablement and
computation hooks. The original tuple-key implementation allocated 1,000,008
objects and took 0.505 seconds; the per-IREP implementation allocated zero
objects and took 0.067 seconds. Both caches were warmed before measurement.
These numbers measure cache hits only, not whole-compiler performance; creating
the new cache costs one inner Hash per queried IREP.
