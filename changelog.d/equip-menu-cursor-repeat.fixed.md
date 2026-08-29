- **Equip menu:** holding Down/Up now auto-repeats the equip-slot list and
  the candidate item list, matching real RPG_RT (continuing the same fix
  already landed for the save/load, field-menu, item, and skill screens).
  The Right/Left actor switch deliberately stays discrete-only, one tap per
  press — confirmed against a reference implementation, not independently
  confirmed against genuine RPG_RT under wine, that the real engine never
  auto-repeats it either, since each switch opens a whole new equip screen
  rather than moving a cursor. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
