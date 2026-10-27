- **bc2cpp:** `array.map(&nil)` (or an absent `&blk` passed on to `map`) no
  longer crashes compiled code. `bc2cpp_ary_collect` yielded to the nil block;
  a block that can be nil now takes the compiled `Enumerable#collect`, which
  returns the Enumerator the interpreter returns. Covered by new cases in
  `scripts/bc2cpp/collect_direct_check.rb`, which also run `select`, `each`,
  `each_with_index`, `reject`, `find`, `sort_by`, Hash, Range and `times` with
  a nil block.
