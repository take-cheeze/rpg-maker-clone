- **RPG2000/2003 maps:** Stepping on a chipset cell whose terrain id has no
  matching database row (a dangling reference left behind by a database
  edit) no longer rolls for a random ("wandering monster") encounter at
  all, matching RPG_RT's own `Game_Player::UpdateEncounterSteps`, which
  skips the step entirely rather than substituting a fallback rate.
  Previously such a tile silently used a fabricated 100% terrain encounter
  rate and could trigger battles real RPG_RT never would from that spot.
  Covered by a new `scripts/rpg2k_scene_check.rb` check.
