- **bc2cpp (Wio):** a compiled method with a single direct call site is
  copied, with internal linkage, into its caller's translation unit, so GCC
  inlines it there and the linker drops the original; the copy also leaves
  out a declared class parameter check that every call site already
  proves. About 16 KB less flash. `BC2CPP_SHARD_COLOCATE=0` /
  `BC2CPP_SHARD_COLOCATE_GUARDS=0` turn the two parts off.
