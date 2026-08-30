- **The field menu now lets you pick which party member Skill/Equip/Status
  applies to, matching genuine RPG_RT.** Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: selecting
  one of those three hands input focus to the party-status panel so you
  pick an actor there (UP/DOWN, confirm with C) before the corresponding
  screen opens for them, rather than always opening for the leader. A
  currently-restricted actor (asleep/paralysed, via the new
  `Game::Actor#can_act?`) cannot be given the Skill command specifically,
  matching RPG_RT -- Equip and Status have no such restriction.
