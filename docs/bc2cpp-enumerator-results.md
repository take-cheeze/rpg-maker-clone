# Blockless Enumerator results

A call to `map` or `collect` with no block, on an exact Array or Hash, returns an
Enumerator. mruby's `Enumerable#collect` (`3rd/mruby/mrblib/enum.rb`) returns
`to_enum(:collect)` when no block is given, and `map` is an alias of it.

bc2cpp's flow records that result as the reserved `NumericFlow::ENUMERATOR` bit
(ADR 0522). The bit names no class, so the codegen treats the value as known to be an
Enumerator but emits no class test or direct call for it.

The declarations are in `sig/bc2cpp/declarations.rbs` under `core_blockless_iterators`.
`Enumerable#map` and `#collect` (which Array and Hash take) have two overloads: the
blockless one returns `Enumerator[untyped, untyped]`, and the block one returns
`Array[untyped]` as in `core_block_iterators`. `CoreBlocklessIteratorSigs`
(`tools/bc2cpp/core_blockless_iterator_sigs.rb`) reads the blockless overload.

Kill switch: `BC2CPP_NATIVE_CLASS_RESULTS=0` removes the result. The check is
`scripts/bc2cpp/enumerator_result_check.rb`; it runs on the host and is listed in
`scripts/coverage/report.rb` and `scripts/ci/bc2cpp_check_policy.yml`.
