- **bc2cpp** compiler: the prepended `compile_send` layers share one options Hash instead of copying the
  keywords at each layer. `compile_insn`, `compile_method`, the ARM_PRUNE walk and the POLY_SMALL_N chain no
  longer build per-instruction Arrays, Strings or memo keys. A few leftover per-call Regexps and copies in
  `NativeExpressionDevirt` and `RegisterFlow` are gone too. Generated C++ is byte-for-byte unchanged. The
  sealed Optcarrot compile allocates about 8.5% fewer objects (see `docs/bc2cpp-emitter-allocations.md`).
