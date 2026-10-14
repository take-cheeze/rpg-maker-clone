- **bc2cpp type reports** infer previously unknown ivar unions from settled
  family-wide class pools, retaining uninitialized nil and refusing opaque,
  reflective, foreign, or guard-dependent writers.
  Independent nominal field and parameter bounds are also recorded in
  `sig/bc2cpp/ir_nominal.rbs`.
