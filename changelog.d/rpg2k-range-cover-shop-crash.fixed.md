- **Opening any shop's Buy list no longer crashes the built engine** (`NoMethodError: undefined method 'cover?' for Range`).
  `Range#cover?` lives in the `mruby-range-ext` core gem, which nothing
  declared; `Game::Shop#equip?` and the special-item type checks in
  `game.rb` / `scene/item_menu.rb` all used it -- `equip?` runs for whichever good is
  highlighted, so every stocked shop crashed the moment its list opened, and
  the Item screen with a special item was reachable too --
  while the CRuby host checks passed. The gem is now in `build_config.rb`'s
  shared list and `mruby-rpg2k/mrbgem.rake`'s dependencies. Found by
  driving the rebuilt engine against Nepheshel's own weapon-shop NPC.
