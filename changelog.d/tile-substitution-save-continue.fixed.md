- **RPG2000/2003 maps:** A live Tile Substitution ("Replace Chipset Tiles")
  now survives a Save/Continue on the same map, matching real RPG_RT —
  previously it was silently dropped on Continue exactly as if the player
  had left and returned to the map, which real RPG_RT only does on an
  ordinary re-visit, not a resumed save. Round-trips through both the
  portable save and a real `.lsd` file. Covered by new
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb` checks.
