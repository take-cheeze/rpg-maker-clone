- **RPG2000 battle:** The Battle/Auto Battle/Escape options window now docks
  to the *left* edge of the screen, with the party status panel pushed to its
  right — not the status panel fixed on the left with the options list on the
  right, which is what every phase of the fight drew before. Ported from a
  reference implementation's own command-window layout logic, not
  independently confirmed against genuine RPG_RT under wine: the options
  window and the per-actor Attack/Skill/Defend/Item command window share the
  same 76px shape and never show at once, but they dock to *opposite* edges —
  the options window before the status window, the per-actor command window
  after it — so the status panel itself now slides between `x=0` (beside the
  command window, unchanged) and `x=76` (beside the options window, the fix)
  depending on which phase is active. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
