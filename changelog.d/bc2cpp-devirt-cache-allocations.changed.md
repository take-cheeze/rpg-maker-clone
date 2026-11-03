- **bc2cpp** compiler: the `NativeExpressionDevirt` scans (class registrations, `analyze`, the exact-class
  bodies and the class-method registrations) are also cached per native file. A world with a new or moved
  file, such as the temporary world of `compiler_profile.rb --optcarrot`, now rescans only that file. A body
  entry is named by the registrations it depends on. `compile_insn_op` tests LOADI ops with `start_with?`
  instead of `/^LOADI/`. Generated C++ is byte-for-byte unchanged. The sealed Optcarrot compile allocates
  3.4% fewer objects with a warm cache and 1.1% fewer with a cold one (see
  `docs/bc2cpp-devirt-cache-allocations.md`).
