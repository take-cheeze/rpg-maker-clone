- **Battle skill hit chance** now uses `CalcSkillToHit`'s fuller agility-adjusted
  physical formula for enemy-scope skills flagged with the "physical" failure
  message (`failure_message == 3`), matching a basic attack's evasion-aware AGI
  roll instead of the flat `skill.hit`; every other skill keeps the flat rate.
  Ported from EasyRPG's `Algo::CalcSkillToHit` into `Game::Party#skill_to_hit`
  and wired into `Game::Party#battle_skill_command`. Covered by seven new checks
  in `scripts/rpg2k_logic_check.rb`.
