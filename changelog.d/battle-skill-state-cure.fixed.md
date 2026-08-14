- **A self/ally-scoped skill's own `state_effects` list now cures states in
  battle**, not just HP/SP — a "Cure Poison"/"Full Recovery"-style skill was
  silently inert on its status half in a fight (only its HP/SP/stat effect
  landed), while the identical medicine *item* already worked and the same
  skill cast from the field menu already worked too. EasyRPG's
  `Game_BattleAlgorithm::Skill::vExecute` settles which polarity applies:
  `heals_states = IsPositive() ^ (Player::IsRPG2k3() && skill.reverse_state_
  effect)`, and under the RPG2000-only reading this runtime models (no
  `Player::IsRPG2k3()` gate), that collapses to "scope alone decides" — a
  self/ally-scoped skill's flagged states always cure, `reverse_state_effect`
  plays no part, mirroring the already-settled `#skill_attr_shift` direction
  fix off the identical formula. `Game::Party#battle_skill_command`'s
  self/ally-scope branch now carries `cured: skill_state_ids(sk)`, threaded
  through `#command_skill`/`#command_skill_all` (the player's battle skill
  menu) and `Game::Battle#skill_command_hash` (the AI-chosen enemy-cast
  path) into `Game::Battle#apply_skill_hit`'s existing, already-tested
  `cmd[:cured]` removal — the same mechanism a battle medicine's own cure
  already used, unconditionally, with no change needed there.
