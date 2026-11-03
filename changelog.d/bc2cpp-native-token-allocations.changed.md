- **bc2cpp** compiler: identifier-token scans over the native sources are also cached per file, so a world
  with a new or moved file rescans only that file instead of every C/C++ source. This applies to
  `outside_world_tokens` and the closed world's native facts. `NativeConstructorSigs` splits each source's
  `mrb_define_method` calls once instead of once per lookup. Generated C++ is byte-for-byte unchanged. The
  sealed Optcarrot compile allocates about 5.1% fewer objects (see `docs/bc2cpp-native-token-allocations.md`).
