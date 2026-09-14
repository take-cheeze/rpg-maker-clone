- `tools/bc2cpp/bc2cpp.rb` now compiles `any?`/`all?`/`none?`/
  `count` literal blocks and `reduce`/`inject(init)` folds (55 sites)
  as native loops on the same inline machinery: boolean destinations
  with early exit, fixnum tally, accumulator seeded once from the
  call's own init register and threaded through block params, and
  `break`-with-value via the established broke-flag pattern. Same
  static Array gate + raise-tripwire, same live-length loop, bodies
  via the shared yielded-value translator. Unlocks 5 methods in
  `mruby-rpg2k-compiled`, zero regressions. Verified against a
  runtime harness (18 cases: hit/miss, empty-array defaults,
  break/next values, capture) plus end-to-end regen. See docs/adr/0155.
