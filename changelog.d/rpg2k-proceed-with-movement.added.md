- **Proceed With Movement** (11340) event command is now handled — the movement
  sync gap observed in the Sample3 common events. It pairs with the existing
  Move Event support: the interpreter pauses until every forced move route in
  progress (player or event) has finished, and `Scene::Map` advances those
  routes while it waits and resumes the interpreter once none remain. As in
  RPG_RT, a repeating forced route never finishes, so pairing it with this
  command waits indefinitely. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
