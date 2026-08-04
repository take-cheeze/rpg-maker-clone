- RPG Maker 2000: **attack-skill damage now varies too**, extending the basic-
  attack variance. A battle skill carries its own `variance` field (0-10, default
  4) on its command, and `apply_command` spreads the skill's damage by it — via
  the same `Algo::VarianceAdjustEffect` port — when the fight has variance enabled
  (the live game; still off for seeded / headless fights, so exact-damage checks
  hold). Covered by a new `scripts/rpg2k_logic_check.rb` check (a Fire skill's
  damage stays within its computed spread and varies across casts) and the
  `battle_skill_command` shape assertion updated for the `variance` key. `FakeSkill`
  gained `variance`.
