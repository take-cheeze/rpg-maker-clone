- bc2cpp's probe compile (`without_probe_side_effects`) removes instance
  variables it created lazily, so a const-site helper registered by a probe no
  longer outlives the flag that emits its support code (generated C++ used
  `bc2cpp_const_try` without defining it).
