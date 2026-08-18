- **Skill menu:** holding a direction now auto-repeats the cursor in the
  skill grid (all four directions), the actor-target list, and the
  registered-teleport-destination list, matching real RPG_RT (continuing
  the same fix already landed for the save/load, main field-menu, and item
  menu screens). Reuses this build's existing, wine-verified
  `Input.repeat?` timing. Covered by a new `scripts/rpg2k_scene_check.rb`
  check.
