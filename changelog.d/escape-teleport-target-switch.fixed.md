- **RPG2000/2003 field skills/items:** A registered Set Teleport Target /
  Set Escape Target's own switch now turns on the instant the party warps
  there via the corresponding Escape/Teleport field skill or special item,
  matching real RPG_RT — previously the switch id was stored correctly but
  silently dropped on the way to the actual warp, so it never flipped.
  Covered by new `scripts/rpg2k_scene_check.rb` checks.
