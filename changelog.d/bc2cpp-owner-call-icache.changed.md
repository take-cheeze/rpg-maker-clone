- **bc2cpp**: an owner call (the closed world's checked by-name call to a core or native method) keeps its last
  checked receiver class and method per call site. A repeat call with the same class skips the method lookup, the
  owner test and the visibility and argument checks, while mruby's own method cache still holds the same entry. In
  the closed build's map and battle traces, 95% of owner calls take this path. `BC2CPP_OWNER_ICACHE=0` at
  generation, or `-DBC2CPP_NO_OWNER_ICACHE`, turns it off. New check `scripts/bc2cpp/owner_call_icache_check.rb`.
