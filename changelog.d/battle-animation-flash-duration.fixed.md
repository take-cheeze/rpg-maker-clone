- **A Battle Animation's own fired screen/target flash now stays visible for
  the correct duration.** `Scene::Map::ANIM_FLASH_FRAMES` was an unverified
  guess of 8 real ticks, force-clearing a fired flash roughly 20% early on
  every single Battle Animation flash timing. Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: its generic flash-update routine keeps a fired timing's colour/power
  alive for 11 raw ticks (0 through 10 inclusive) from the tick
  it fires — before falling back to all-zero. Fixed by changing the constant
  to 11. Covered by a new `scripts/rpg2k_scene_check.rb` check, confirmed to
  fail against the pre-fix code before the fix.
