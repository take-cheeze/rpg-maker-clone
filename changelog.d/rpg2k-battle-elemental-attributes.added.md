- RPG Maker 2000: **battle damage now respects elemental attributes**. A weapon's
  `attribute_set` (surfaced via `Game::Actor#weapon_attributes`) and a skill's
  `attribute_effects` (`Game::Party#skill_attributes`) name the elements an attack
  carries; each battler's per-attribute defence ranks
  (`Game::Actor#attribute_ranks` / `Game::Enemy#attribute_ranks`, read from the
  database `attribute_ranks` byte array) are snapshotted onto the `Combatant`.
  `Battle#deal_attack` and the skill path scale the base damage by the target's
  resistance before variance and criticals — rank A..E maps to 200 / 150 / 100 /
  50 / 0 percent, taking the strongest matching element (EasyRPG's
  `Attribute::ApplyAttributeMultiplier`), so a foe takes extra damage from a
  weakness and takes none at all from an element it is immune to. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (weakness amplifies, resistance halves,
  immunity nullifies, the strongest element wins, an unlisted element is
  unchanged, and the readers feed the snapshot). Per-attribute rate overrides
  from the database Attribute table (every element currently uses the RPG2000
  defaults) remain a follow-up.
