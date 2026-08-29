- **A self/ally-scoped skill's own `state_effects` list now cures states in
  battle**, not just HP/SP — a "Cure Poison"/"Full Recovery"-style skill was
  silently inert on its status half in a fight (only its HP/SP/stat effect
  landed), while the identical medicine *item* already worked and the same
  skill cast from the field menu already worked too. A reference
  implementation's own skill-execution algorithm settles which polarity
  applies (ported from that source, not independently confirmed against
  genuine RPG_RT under wine): the positive/negative scope of the skill,
  combined with the RPG2003-only reverse-state-effect flag, decides whether
  it heals states, and under the RPG2000-only reading this runtime models
  (no RPG2003 gate), that collapses to "scope alone decides" — a
  self/ally-scoped skill's flagged states always cure, `reverse_state_effect`
  plays no part, mirroring the already-settled `#skill_attr_shift` direction
  fix off the identical formula. `Game::Party#battle_skill_command`'s
  self/ally-scope branch now carries `cured: skill_state_ids(sk)`, threaded
  through `#command_skill`/`#command_skill_all` (the player's battle skill
  menu) and `Game::Battle#skill_command_hash` (the AI-chosen enemy-cast
  path) into `Game::Battle#apply_skill_hit`'s existing, already-tested
  `cmd[:cured]` removal — the same mechanism a battle medicine's own cure
  already used, unconditionally, with no change needed there.
