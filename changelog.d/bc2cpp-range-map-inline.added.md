- bc2cpp inlines `(a..b).map { |i| ... }` over two Integer literals as a counted loop (RANGE_MAP_INLINE), in a
  method body and inside a BLOCK_FALLBACK body, instead of calling `Enumerable#collect` with an allocation and a
  `block.call` per element. See `docs/bc2cpp-range-map-inline.md`; checked by
  `scripts/bc2cpp/range_map_inline_check.rb`.
