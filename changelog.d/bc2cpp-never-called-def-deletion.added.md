- **A genuinely dead method's checked-in `def` can now be deleted outright**,
  not just have its bc2cpp AOT registration pruned (docs/adr/0193) — but only
  after `scripts/bc2cpp_def_deletion_safety_check.rb` confirms, with a plain
  repo-wide text search, that nothing outside the engine's own mrblib (tests,
  `scripts/*.rb` check harnesses, docs) calls it either — bc2cpp.rb's own
  "never called" diagnostic has no visibility into any of those. This caught
  a real near-miss: `LCF::Database#maker` looked identically dead to
  `Game::Character#front_tile`, but is called from `mruby-lcf/test/
  lcf_test.rb` and two host-side check scripts — its `def` was left alone.
  `Game::Character#front_tile`'s `def` (confirmed to have zero references
  anywhere in the repository) was deleted. See docs/adr/0194.
