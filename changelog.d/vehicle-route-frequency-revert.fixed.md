- **Vehicle move routes:** A boat/ship/airship's Move Frequency now reverts
  to whatever it was before a forced Move Route started, once that route
  finishes, instead of staying permanently overwritten by a Frequency Up/
  Down sub-command or the route's own frequency parameter, matching RPG_RT.
  Covered by a new `scripts/rpg2k_scene_check.rb` check.
