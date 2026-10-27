- **bc2cpp** cuts optcarrot's startup. `map` on an exact Array calls a direct
  loop instead of Enumerable#collect's per-element splats (COLLECT_DIRECT,
  `docs/bc2cpp-collect-direct.md`). The native ROM-table owner scan resolves
  classes defined under an outer class (mruby-socket's `Socket::Option`),
  which unblocks the `Array.new(n) { }` inlining in `Array#transpose`.
