- **Input Number widget:** On a single-digit prompt, Right no longer moves
  the cursor or plays the Cursor sound effect -- matching RPG_RT, it is a
  complete no-op there, while Left still plays the sound as before.
  Covered by a new `scripts/rpg2k_scene_check.rb` check.
