- **Opening a shop whose highlighted good is equipment no longer crashes the
  built engine** (`NoMethodError: undefined method 'cover?' for Range`).
  `Range#cover?` lives in the `mruby-range-ext` core gem, which nothing
  declared; `Game::Shop#equip?` and the special-item type checks in
  `game.rb` / `scene/item_menu.rb` all used it, so the crash was reachable
  from any equipment shop and from the Item screen with a special item,
  while the CRuby host checks passed. The gem is now in `build_config.rb`'s
  shared list and `mruby-rpg2k/mrbgem.rake`'s dependencies. Found by
  driving the rebuilt engine against Nepheshel's own weapon-shop NPC.
