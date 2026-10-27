- **bc2cpp:** an inlined `(a..b).each { }` / `(a...b).each { }` no longer
  raises `TypeError: non-Integer Range#each left to interpreter` on String,
  Float or bigint bounds. The Integer counter loop now runs behind a bounds
  guard and every other Range takes the ordinary `Range#each` send. Covered
  by `scripts/bc2cpp/range_each_guard_check.rb`.
