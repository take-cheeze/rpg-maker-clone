- **RPG2000/2003 maps:** The Enter Hero Name widget now plays RPG_RT's
  system SE on every interaction — Cursor on each grid move, Decision on
  every confirm (before dispatching on the highlighted cell), Buzzer when a
  character would overflow the field, and Cancel (or Buzzer with nothing
  left to erase) on backspace — previously it played no sound effects at
  all. Covered by a new `scripts/rpg2k_scene_check.rb` check.
