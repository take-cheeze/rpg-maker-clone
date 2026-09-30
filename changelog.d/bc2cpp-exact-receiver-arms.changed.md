- `tools/bc2cpp/bc2cpp.rb` drops the class test (and, for the frame-independent native arms, the
  dynamic send) of NATIVE_CORE_DIRECT, NATIVE_DIRECT and BLOCK_CORE_DIRECT arms whose receiver is
  provably exact: an Array/Hash/Range/String literal, a `*rest` array or a fresh RGSS `Klass.new`,
  in a closed world where no object can gain a singleton class (`ClosedWorld#exact_instances_singleton_free?`).
  A block arm keeps its else so a Fiber still reaches the bytecode. Wio: 10954 to 10940 cached
  dispatch sites. Covered by `scripts/bc2cpp_exact_receiver_check.rb`. See docs/adr/0280.
