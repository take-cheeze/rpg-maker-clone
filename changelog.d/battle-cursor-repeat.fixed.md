- **Battle:** holding Down/Up now auto-repeats every cursor in the battle
  UI — the options window (Fight/Auto Battle/Escape), the per-actor command
  list, and the Skill/Item/enemy-target/ally-target lists — matching real
  RPG_RT. This closes out the key-repeat fix already landed for the
  save/load, field-menu, item, skill, equip, order, and title screens; only
  the classic F9 debug menu remains open, pending a genuine reference for
  its original behavior. Covered by a new `scripts/rpg2k_scene_check.rb`
  check.
