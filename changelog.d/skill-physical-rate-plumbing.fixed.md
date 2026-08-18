- **A physical skill's chance to shake loose a status now actually fires for
  a real cast.** `Game::Battle#command_skill`/`#command_skill_all` — the only
  two ways a queued skill's command hash is ever built, for the player's
  menu or an AI cast alike — had no `physical_rate:` keyword at all, so the
  effect always rolled against 0 regardless of the skill's own value.
  `#skill_command_hash` (the enemy/auto-battle single-target wrap) dropped
  `attr_shift`/`attr_ids`/`stat_mod_keys`/`stat_effect`/`physical_rate`
  outright the same way. All five now survive from `battle_skill_command`'s
  computed result through to `#apply_skill_hit`.
