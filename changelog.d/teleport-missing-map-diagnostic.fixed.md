- **Transfer Player / Recall to Location naming a deleted map no longer
  crashes the whole interpreter.** `Scene::Map#perform_teleport`
  (`mruby-rpg2k/mrblib/scene/map.rb`) now catches a failed map load and
  reports a `[RPG2k] Teleport: destination map #<id> failed to load: ...`
  diagnostic (the underlying message carries the literal missing filename,
  matching real RPG_RT's own error dialog) instead of letting the raw
  `Errno::ENOENT` from `RPG2k#load_map` propagate out unhandled; the party
  stays on the map they were already on. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks.
