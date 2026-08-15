- Real RPG2k's **Battle/Auto Battle/Escape options window** is now modelled:
  it shows automatically once at the very start of every fight, right after
  the encounter/turn-0-event messages resolve, and reopens on B/Cancel
  landing on the first commandable actor's command list -- replacing the
  engine's old direct-B-press Escape shortcut. Battle falls through to the
  ordinary per-actor command menu; Auto Battle queues
  `Game::Battle#choose_auto_battle_command`'s AI pick (already used for
  Forced-AI actors) for every commandable living ally and starts the round;
  Escape reuses the existing escape-chance roll unchanged. A party entirely
  restricted or Forced-AI'd bypasses the window, matching real RPG_RT's
  `IsAnyControllable()` guard, and the window never reappears automatically
  at round 2+. Uses the database's `battle_fight`/`battle_auto`/
  `battle_escape` terms (schema fields 101/102/103), falling back to English.
  Covered by new checks in `scripts/rpg2k_scene_check.rb`.
