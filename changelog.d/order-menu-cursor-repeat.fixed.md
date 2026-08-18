- **Order screen (RPG2003):** holding Down/Up now auto-repeats both the
  party-reordering pick cursor and the Confirm/Redo prompt cursor, matching
  real RPG_RT — confirmed against EasyRPG's source that both genuinely
  auto-repeat here (unlike the equip and status screens' discrete-only
  actor switches). Continues the same fix already landed for the save/load,
  field-menu, item, skill, and equip screens. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
