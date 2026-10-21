# Blockless Enumerator results

A call to an Enumerable iterator with no block, such as `map`, `select` or `each_slice(n)`, on an
exact core receiver that includes Enumerable (Array, Hash, Range), returns an Enumerator. mruby returns
`to_enum(:name, *args)` from those iterators when no block is given (`3rd/mruby/mrblib/enum.rb`,
`mruby-enum-ext`), and some aliases such as `map` and `filter` point at them.

bc2cpp's flow records that result as the reserved `NumericFlow::ENUMERATOR` bit
(ADR 0524). The bit names no class, so the codegen treats the value as known to be an
Enumerator but emits no class test or direct call for it.

The declarations are in `sig/bc2cpp/declarations.rbs` under `core_blockless_iterators`.
Each Enumerable iterator mruby answers with `to_enum` is declared there as the method-level union of
two overloads: the blockless one returns `Enumerator[untyped, untyped]` with the arity its call accepts,
and the block one takes a block. The block overload's result is the class `core_block_iterators`
declares where it does, else `untyped`. `find_index` is not declared: its blockless call with an
argument is not an Enumerator. The loader refuses a member that has only one form. `CoreBlocklessIteratorSigs`
(`tools/bc2cpp/core_blockless_iterator_sigs.rb`) reads the results and the arity.

Kill switch: `BC2CPP_NATIVE_CLASS_RESULTS=0` removes the result. The check is
`scripts/bc2cpp/enumerator_result_check.rb`; it runs on the host and is listed in
`scripts/coverage/report.rb` and `scripts/ci/bc2cpp_check_policy.yml`.
