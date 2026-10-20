# Blockless Enumerator results

A call to `map` or `collect` with no block, on an exact Array or Hash, returns an
Enumerator. mruby's `Enumerable#collect` (`3rd/mruby/mrblib/enum.rb`) returns
`to_enum(:collect)` when no block is given, and `map` is an alias of it.

bc2cpp's flow records that result as the reserved `NumericFlow::ENUMERATOR` bit
(ADR 0522). The bit names no class, so the codegen treats the value as known to be an
Enumerator but emits no class test or direct call for it.

The declarations are in `sig/bc2cpp/declarations.rbs` under `core_block_results`.
`map` and `collect` on Array and Hash have two overloads: the blockless one returns
`Enumerator[untyped, untyped]`, and the block one returns `Array[untyped]`. The loader
(`NativeCoreResultSigs.load_kinds(form:)`) reads each overload by its form.

Kill switch: `BC2CPP_NATIVE_CLASS_RESULTS=0` removes the result. The check is
`scripts/bc2cpp/enumerator_result_check.rb`; it runs on the host and is listed in
`scripts/coverage/report.rb` and `scripts/ci/bc2cpp_check_policy.yml`.
