- **bc2cpp**: an inlined block loop (`ary.each { }`, `n.times { }`, `map`,
  `sort_by`, ...) inside a `rescue`-protected range is no longer also emitted
  into the enclosing method's own function, where it ran only after an
  exception, on a receiver register holding the exception object. In the
  `RPGMAKER_BC2CPP=1` build this turned any error inside
  `RPG2k#start_new_game` (kk1.12's New Game) into
  `TypeError: bc2cpp: expected Array receiver for inlined #each` instead of
  the method's own `[RPG2k] Failed to start new game: ...` log line. The call
  inside the extracted try body keeps its real dynamic dispatch. Covered by
  `scripts/bc2cpp_rescue_inline_block_check.rb`.
