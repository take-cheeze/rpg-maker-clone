- **Terrain footstep SE**: the database terrain fields `footstep` and
  `on_damage_se` (parsed since the terrain chunk was first decoded, never
  read) are wired up, matching a reference implementation's player-movement
  handling exactly — ported, not independently confirmed against genuine
  RPG_RT under wine — the footstep SE is RPG2003-only, and `on_damage_se`
  turns it from an ordinary
  per-step sound into one that only plays on a step that actually dealt
  terrain damage. `Scene::Map#play_terrain_footstep_se`
  (`mruby-rpg2k/mrblib/scene/map.rb`) plays it from the same `#terrain_row_at`
  lookup `#note_party_step` already made for the terrain damage tick.
