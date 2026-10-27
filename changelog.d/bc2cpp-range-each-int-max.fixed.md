- **bc2cpp:** an inlined `(a..b).each { }` whose inclusive end is
  `MRB_INT_MAX` now takes the ordinary `Range#each` send instead of the
  counter loop, so it yields what the interpreter yields (mruby compares the
  bigint `last + 1` as a double there and stops short). Covered by new edge
  cases in `scripts/bc2cpp/range_each_guard_check.rb`.
