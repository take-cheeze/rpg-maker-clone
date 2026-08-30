- **Order screen (RPG2003):** holding Down/Up now auto-repeats both the
  party-reordering pick cursor and the Confirm/Redo prompt cursor, matching
  real RPG_RT — a reference implementation shows both genuinely
  auto-repeat here (unlike the equip and status screens' discrete-only
  actor switches), though not independently confirmed against genuine
  RPG_RT under wine. Continues the same fix already landed for the save/load,
  field-menu, item, skill, and equip screens. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
