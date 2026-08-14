- **A map's own configured BGM now auto-plays on entry**, on the initial map
  load and every Transfer Player alike, instead of requiring an explicit Play
  BGM event command on every map. The map tree's `bgm_type`/`bgm` fields
  (RPG_RT.lmt) were already parsed but never read anywhere in `mruby-rpg2k`.
  A new `Game::MapBgm` module resolves the same parent-inheriting tri-state
  walk `Game::Backdrop`/`Game::MapAccess` already use for backdrop and
  Save/Teleport/Escape access, and `Scene::Map#play_map_bgm` (called
  alongside the existing `#apply_map_access`) routes the result through the
  already same-file-aware `#play_bgm` helper, so a Transfer Player back onto
  the same map — or between two maps sharing a track — does not restart it.
  Skipped while boarded on a vehicle, whose own BGM owns the audio until
  disembarking. Covered by new `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
