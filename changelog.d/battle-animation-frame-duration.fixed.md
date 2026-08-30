- **A Show Battle Animation frame is now held for 1/30s (2 ticks at 60fps),
  not 1/20s (3 ticks).** `Scene::Map::ANIM_CELL_FRAMES` was `3`; a reference
  implementation's animation-update step (ported from that source, not
  independently confirmed against genuine RPG_RT under wine) ticks its internal
  frame counter once per logical 60fps update and renders the cell index at
  half that counter — every real (LCF)
  animation frame is held for exactly 2 ticks, whether or not that frame's
  own cell list is empty, with no separate doubling rule for "Wait" frames
  specifically. Fixed by changing the constant to `2`. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code before the fix.
