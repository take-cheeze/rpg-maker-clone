- **bc2cpp** cuts optcarrot's startup: `map` on an exact Array calls a direct
  loop instead of Enumerable#collect's per-element splats (COLLECT_DIRECT,
  `docs/bc2cpp-collect-direct.md`), `!=` compares two Integers without a
  by-name `==`, POLY_SMALL_N chains test Integer/Float/Symbol by type tag, and
  the native ROM-table owner scan resolves classes defined under an outer
  class (mruby-socket's `Socket::Option`), which unblocks the `Array.new(n) { }`
  inlining in `Array#transpose`. Covered by
  `scripts/bc2cpp/collect_direct_check.rb` and
  `scripts/bc2cpp/native_rom_owners_check.rb`.
