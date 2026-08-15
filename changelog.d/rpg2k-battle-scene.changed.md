- **rpg2k: the turn-based fight is now its own `Scene::Battle`**, not a mode
  of `Scene::Map`. The command/target/skill/item windows, troop and party
  sprites, round animation, battle-event pages and result screen all moved
  out of `mruby-rpg2k/mrblib/scene/map.rb` into a new
  `mruby-rpg2k/mrblib/scene/battle.rb`; `Scene::Map` now constructs and drives
  a `Scene::Battle` instance for the duration of an encounter instead of
  threading a `@battle_ui` hash through its own methods. Purely an
  architectural change — no mechanic, timing or on-screen behaviour differs;
  see ADR 0052 for the design and `scripts/rpg2k_scene_check.rb` (628 checks)
  / `scripts/rpg2k_logic_check.rb` (907 checks) for the unchanged coverage.
