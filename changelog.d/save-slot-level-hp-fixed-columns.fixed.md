- **Save/Load screen:** A save slot's level and HP now draw at RPG_RT's own
  fixed pixel columns, each number space-padded to a fixed width -- a
  leader's level going from one digit to two used to shift the "HP" label
  sideways, since the line drew as a single string with a literal gap
  instead of separately positioned fields. Covered by new
  `scripts/rpg2k_scene_check.rb` checks.
