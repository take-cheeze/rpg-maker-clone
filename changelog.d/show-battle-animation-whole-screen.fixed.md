- **RPG2000/2003 maps:** Show Battle Animation's "Whole screen" target
  option now actually tiles the animation across the entire visible
  screen, matching RPG_RT. Previously this parameter was silently
  ignored and every such animation rendered as a small effect anchored to
  the target character instead of a screen-wide wash. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks.
