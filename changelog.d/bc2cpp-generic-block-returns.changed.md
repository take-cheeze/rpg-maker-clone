- **bc2cpp** (ADR 0475): RBS declarations `[T] (...) { (...) -> T } -> T` and `{ ... } -> self` are now checked and
  used. A call with a literal block keeps the class of its block's value, or of its receiver, and the block keeps the
  caller's self. Each declaration is checked against what defines it: the bytecode of a Ruby definition, or a scan
  of a native's C function. A native the scan cannot verify must be listed, with its file's SHA-256, in
  `tools/bc2cpp/native_block_returns_reviewed.rb`. A false declaration fails the build (TC1010).
  `RGSS::Profiler.section`/`.frame`, `Kernel#tap`/`#then`/`#yield_self` and `Array#each` are declared. The
  Profiler-only PROFILER_RESULTS proof, its profiler.cxx SHA pin and its `BC2CPP_PROFILER_RESULTS` and
  `BC2CPP_PROFILER_NAME_SCOPED` switches are removed. New check `scripts/bc2cpp/generic_block_return_check.rb`.
