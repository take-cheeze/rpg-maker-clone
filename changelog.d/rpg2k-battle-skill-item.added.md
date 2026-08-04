- The battle command menu now offers **Skill** and **Item** alongside Attack and
  Defend. Choosing *Skill* lists the actor's battle-usable skills with their SP
  cost and casts the picked one — an attack skill damages a chosen enemy (base
  effect less a quarter of its defence), a recovery skill restores a chosen ally
  (or the caster), and the SP is spent when the action lands; a skill the caster
  cannot afford is not selectable. Choosing *Item* lists the party's battle
  medicines and uses the picked one on a chosen ally, restoring HP / SP and
  consuming one from the bag when the action lands (so backing out first spends
  nothing). Effects resolve in agility order during the per-turn animation, with
  the cast / heal bannered like an attack, and the status panel now shows each
  member's SP as well as HP. `Game::Battle` gained `command_skill` /
  `command_item` (single-target, applied by `#apply_command`, cleared each round)
  and the Combatant snapshot now carries SP and spirit; `Game::Party` gained the
  battle-context helpers that reuse the field formulas — `battle_skills`,
  `battle_skill_target`, `battle_skill_command`, `battle_items`,
  `battle_item_command`. This is a single-target first cut: all-target scopes
  (all enemies / all allies), battle SP / damage variance and status-inflicting
  skills are still to come, as are battler sprites and game over on defeat.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` (battle skill listing /
  command numbers, attack- and heal-skill and item resolution, a cast fizzling on
  a fallen target) and `scripts/rpg2k_scene_check.rb` (casting an attack skill,
  using an item mid-battle).
