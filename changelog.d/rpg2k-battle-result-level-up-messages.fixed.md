- **RPG2000 battle victory result screen** now announces a level-up and any
  skill it teaches, the same way the Change EXP / Change Level event commands
  already do, reading the database's own `level`/`level_up`/`skill_learned`
  terms (falling back to composed English when they're blank). Covered by two
  new `scripts/rpg2k_scene_check.rb` checks.
