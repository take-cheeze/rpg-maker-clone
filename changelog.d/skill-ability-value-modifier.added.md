- **A skill flagged to raise or lower ATK/DEF/SPI/AGI (schema fields 33-36,
  `affect_attack`/`affect_defense`/`affect_spirit`/`affect_agility`) now
  actually does so**, instead of being parsed and read nowhere. Ported from
  EasyRPG Player's actual C++ source (`src/game_battlealgorithm.cpp`'s
  `Game_BattleAlgorithm::Skill::vExecute`, `src/game_battler.cpp`'s
  `Game_Battler::CanChangeAtkModifier` and its DEF/SPI/AGI siblings): each
  flag applies the skill's own signed effect — the identical
  post-attribute-scaling, post-variance, post-cap number `affect_hp`/
  `affect_sp` already use for the same hit — to a per-battle modifier,
  clamped to `-(base/2)..+base` (`base` the battler's own raw stat) and reset
  to 0 every fresh fight for free, since a `Game::Battle::Combatant` (which
  now carries new `atk_mod`/`def_mod`/`spi_mod`/`agi_mod` fields) is built
  once per fight and never written back to the actor — the same pattern the
  attribute-defence-shift feature already established for `attr_ranks`.
  `Game::Party#skill_stat_mod_keys` reads the four flags; `battle_skill_command`
  threads them (plus, for a buff-only skill with `affect_hp` clear, the raw
  effect a `hp: 0` command still needs) through to `Game::Battle#
  apply_stat_mods`, which clamps and applies the delta from `apply_skill_hit`
  on both the attack and heal/buff branches. `effective_atk`/`effective_def`/
  `effective_spi`/`effective_agi` now read the modifier — clamped to a new
  `MAX_STAT_BATTLE_VALUE = 9999` — *before* a state's own halve/double is
  applied on top, matching EasyRPG's own `AdjustParam` ordering. The clamp's
  lower bound is deliberately `-(base / 2)` (dividing the positive `base`
  first, then negating) rather than the more natural-looking `-base / 2`:
  EasyRPG's C++ expression truncates toward zero (base 5 → -2), while Ruby's
  own `/` on a negated numerator floors toward -infinity instead (`-5 / 2`
  = -3) — reproducing this asymmetry between "a special skill's ability-value
  decrease rounds up on ÷2" and "a status effect's own halving rounds down"
  was the whole point of the fix. Wired into the actual battle-menu UI path
  (`Scene::Map#apply_pending_skill`/`#apply_pending_skill_all`); an enemy AI's
  own skill cast is left unwired, matching the attribute-defence-shift
  feature's own scope (`Game::Battle#skill_command_hash` never carried
  `attr_shift`/`attr_ids` either). Covered by five new
  `scripts/rpg2k_logic_check.rb` checks, four confirmed to fail against the
  pre-fix code before the fix.
