- **bc2cpp** compiler: fewer temporary Strings while emitting and scanning text. RegisterFlow reads register
  numbers from the digit bytes, the dead-statement pass and line indentation no longer split code into
  per-line Strings, identifier stems skip three `chomp` copies, and the Comparable model check lays out each
  core source once instead of once per operator. Generated C++ is byte-for-byte unchanged; the sealed
  Optcarrot compile allocates about 4.5% fewer objects (see `docs/bc2cpp-text-allocations.md`).
