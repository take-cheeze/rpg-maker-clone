- **RPG2000/2003 maps:** A map event's own database Move Speed is now
  converted into this engine's internal scale before use, matching real
  RPG_RT — previously the raw database value was fed straight through
  unconverted, so an ordinary, unconfigured NPC (database default "Normal")
  walked at exactly the hero's own pace instead of real RPG_RT's slower
  default, and every other explicit event Move Speed was off by one full
  notch (2x too fast). The slowest Move Speed setting is also now reachable
  instead of silently clamping up to the next notch. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks and a corrected
  `scripts/rpg2k_logic_check.rb` clamp-bounds check.
