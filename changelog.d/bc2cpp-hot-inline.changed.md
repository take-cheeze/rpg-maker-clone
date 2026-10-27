- **bc2cpp**: the per-element Array helpers (`bc2cpp_ary_entry`, `bc2cpp_ary_push`, `bc2cpp_ary_set` and
  `bc2cpp_getidx`'s inline front) are always inlined, except in `-Os` builds
  ([HOT_INLINE](docs/bc2cpp-hot-inline.md)). GCC's `-O3` heuristics had been dropping one of them from large
  callers. In the optcarrot probe the frame loop drops from 36.00M to 35.43M instructions per frame
  (callgrind), for 75 KB more `.text`. New check `scripts/bc2cpp/hot_inline_check.rb`.
