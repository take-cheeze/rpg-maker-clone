- **bc2cpp**: the receiver trace and the bytecode loader allocate fewer host
  objects. The trace passes its options by name instead of forwarding splats.
  Its in-progress memo uses packed Integer keys, and lexical constant
  candidates come from a frozen-string cache. The RITE reader unpacks fields in
  place, `OperandSchema.parse` is memoized, and the decoder shares frozen
  sym, name, addr and argc operands. Predecessor and per-op index lists skip
  their intermediate Arrays. A sealed Optcarrot compile allocates about 5.9%
  fewer objects, and its generated C++ is byte-identical. See
  `docs/bc2cpp-trace-loader-allocations.md`.
