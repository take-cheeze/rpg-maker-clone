- **Battle skill hit chance** now uses a fuller agility-adjusted
  physical formula for enemy-scope skills flagged with the "physical" failure
  message (`failure_message == 3`), matching a basic attack's evasion-aware AGI
  roll instead of the flat `skill.hit`; every other skill keeps the flat rate.
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine, into `Game::Party#skill_to_hit`
  and wired into `Game::Party#battle_skill_command`. Covered by seven new checks
  in `scripts/rpg2k_logic_check.rb`.
