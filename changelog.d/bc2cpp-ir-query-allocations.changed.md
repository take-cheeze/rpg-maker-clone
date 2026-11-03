- **bc2cpp**: the bytecode IR and instruction decoder allocate fewer host
  objects. Single-op instruction queries return the shared per-op index list,
  `BytecodeIR.reaching_definitions` takes explicit keywords instead of an
  options Hash, reaching-definition and write-dominance caches skip per-call
  key Arrays and copies, and the decoder shares frozen register, integer and
  fixed-literal operands. A sealed Optcarrot compile allocates about 6–7%
  fewer objects, with byte-identical generated C++. See
  `docs/bc2cpp-ir-query-allocations.md`.
