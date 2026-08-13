- **The Open Shop buy list now carries a stat-comparison indicator on
  equippable goods**, matching the yado.tk finding that RPG_RT's own arrow
  is one aggregate Up/Same/Down symbol from the *sum* of all four
  battle-stat deltas (Atk/Def/Int/Agi) between the candidate and whatever
  the party's front actor currently has worn in that slot, not four
  separate per-stat arrows. `Game::Shop#stat_arrow` (`mruby-rpg2k/mrblib/
  game.rb`) returns 1 / 0 / -1, or `nil` for a non-equipment good (a
  medicine, a skill book) or an empty party; `Scene::Map#shop_lines`
  (`mruby-rpg2k/mrblib/scene/map.rb`) appends a ` +`/` -` suffix to the
  buy-list row accordingly, leaving a same-value or non-equipment row
  untouched.
