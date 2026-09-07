- **New Game crashed on Android (and anywhere else `mruby-fiber` is linked
  without `mruby-enumerator`) with `NotImplementedError: fiber required for
  enumerator`.** `build_config.rb` links `mruby-fiber` but not
  `mruby-enumerator`, so mruby's `to_enum` stub
  (`3rd/mruby/mrblib/kernel.rb`) raises whenever an `Enumerable` method is
  called with no block — `Array#each_index`/`#each_with_index` included.
  `Game::Actor#normalize_equipment` (`mruby-rpg2k/mrblib/game.rb`), on the
  New Game path the Android smoke test walks, called
  `EQUIP_ORDER.each_index.map { ... }` this way, and five more call sites in
  the same file plus two in `mruby-rpg2k/mrblib/scene/battle.rb` had the
  same shape. Rewritten to build the result array directly
  (`Array.new(n) { |i| ... }`) instead of chaining off a blockless
  `each_index`/`each_with_index`, so no code path depends on mruby's
  enumerator support.
