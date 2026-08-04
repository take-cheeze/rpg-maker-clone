- The **Enemy Encounter** (10710) event command is now handled, and the runtime
  battle model it needs has landed: `Game::Enemy` instantiates a database enemy
  (combat stats, EXP / gold, battle position, full starting HP / SP) and
  `Game::Troop` instantiates an enemy group (敵グループ) into its live members and
  totals the EXP / gold it is worth. The command decodes its parameters
  (constant or variable troop id, escape mode — disallow / end-event / custom
  handler — defeat mode, first-strike) and, like the inn and shop, routes the
  optional `[Victory]` / `[Escape]` / `[Defeat]` handler branches (markers 20710 /
  20711 / 20712, closed by 20713) on the outcome; the "end event processing"
  escape mode abandons the rest of the event. `Game::Interpreter` suspends on a
  `:battle` wait. The turn-based battle screen is not built yet, so `Scene::Map`
  resolves an encounter as an **immediate victory** that grants the troop's EXP
  (to every party member) and gold, then runs the Victory handler — a
  placeholder until the real battle system lands. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
