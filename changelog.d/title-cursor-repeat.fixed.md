- **Title screen:** holding Down/Up now auto-repeats the New Game/Continue/
  Shutdown cursor, matching real RPG_RT — continuing the same fix already
  landed for the save/load, field-menu, item, skill, equip, and order
  screens. Reuses this build's existing, wine-verified `Input.repeat?`
  timing. Covered by a new `scripts/rpg2k_scene_check.rb` check.
