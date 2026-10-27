- **bc2cpp** (`TRANSPOSE_DIRECT`): the compiled core `Array#transpose` body now first calls
  `bc2cpp_ary_transpose`, which builds the result in C for an exact Array of exact equal-length Arrays and
  otherwise hands over to the compiled body. That covers subclasses, singletons, non-Array rows and ragged rows,
  which keep their exact errors. The helper is emitted only while the mruby-array-ext body is still the pinned
  text and everything it calls is mruby's own. optcarrot's `TILE_LUT` transpose drops from 409M to 153M
  instructions, and startup falls by 17.5% (1,488M to 1,228M under callgrind); per-frame cost is unchanged.
  `BC2CPP_TRANSPOSE_DIRECT=0` keeps the compiled body alone. See `docs/bc2cpp-transpose-direct.md`; the new check
  is `scripts/bc2cpp/transpose_direct_check.rb`.
