- **RPG2003 battles:** A troop member killed by a scripted Change Monster HP
  event command now plays the enemy-kill sound effect, matching RPG_RT.
  Previously a scripted kill (a battle-event page's damage-over-time tick,
  a scripted boss-phase kill) finished the monster off in total silence,
  unlike an ordinary lethal Attack or Skill. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
