- **bc2cpp generated C++** compiles with far fewer warnings. Unused register
  copies, labels and self-assignments are no longer emitted, and neither are
  constant-lookup helpers that only a discarded body called. Entry wrappers a
  hand-written registration may skip, and the shared prelude helpers, are
  `[[maybe_unused]]`. Clang no longer sees GCC's `noipa`. Two dead functions in
  `mruby-rgss` (a stray `sprite_new_direct` declaration and the uncalled
  `flush_encoder_to_stdout`) are removed.
