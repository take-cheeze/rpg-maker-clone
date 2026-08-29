- RPG Maker 2000: confirmed the status screen's Left/Right actor cycling
  already matches real RPG_RT, no code change needed — unlike the
  list/grid cursors already fixed to auto-repeat on the save/load, field
  menu, item, skill, and equip screens, the status screen's update logic in
  a reference implementation (ported from its real source, not
  independently confirmed against genuine RPG_RT under wine) checks a
  single-press trigger only, since Left/
  Right there rebuilds the whole panel for a different party member
  rather than moving a cursor. Pinned with a new
  `scripts/rpg2k_scene_check.rb` check.
