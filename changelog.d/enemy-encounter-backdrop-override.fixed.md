- **Battles:** Enemy Encounter's own per-fight battle backdrop override is
  now honored, matching real RPG_RT — an event author naming an explicit
  background image, or an explicit terrain to read one from, used to be
  silently discarded, every scripted encounter falling back to the ordinary
  map/terrain default regardless of what was actually chosen. Covered by two
  new `scripts/rpg2k_scene_check.rb` checks.
