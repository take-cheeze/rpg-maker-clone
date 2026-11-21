- **bc2cpp**: `sig/bc2cpp/declarations.rbs` declares the battler parameters of `Game::Battle`'s action chain
  (and `Scene::Battle#force_ai_actor?` / `#draw_battle_gauge_card`) as `Game::Battle::Combatant`, the battle
  rosters and queue as Arrays of them, `Game::Actor@skills` / `Scene::Menu@commands` as Arrays and
  `@ui[:pending]` as an optional Hash. The closed build has 25 fewer by-name owner calls in mruby-rpg2k.
