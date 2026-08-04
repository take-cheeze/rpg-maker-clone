- Enemy Encounters now **resolve an actual battle** instead of an automatic
  win. A new `Game::Battle` runs a headless turn-based fight of the party
  against the troop: battlers act in agility order (highest first), each striking
  a random living opponent for `max(1, attack / 2 − defence / 4)` damage, until
  one side is wiped — `:victory` when every enemy is down, `:defeat` when the
  whole party is. `Scene::Map` runs it on Combatant snapshots, so a resolved
  battle leaves the party's real HP untouched for now, and grants the troop's
  EXP / gold only on a win. This is a deliberately simple first cut: no skills,
  items, criticals, attributes, damage variance or escape, and the on-screen
  turn-based battle (which would show and persist HP) plus game over on defeat
  are still to come. Covered by new checks in `scripts/rpg2k_logic_check.rb`
  (damage formula, stronger party wins / weaker loses, agility turn order) and
  `scripts/rpg2k_scene_check.rb`.
