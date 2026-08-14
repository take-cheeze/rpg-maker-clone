- **Continue now resumes the save's own remembered BGM track instead of
  recomputing it fresh from the map tree.** `Scene::Map#initialize` called
  `#play_map_bgm` unconditionally regardless of `apply_access:` — the same
  keyword `RPG2k#continue_game` already passes `false` for the analogous
  Save/Teleport/Escape-access gap — so resuming a save with a Play BGM
  override mid-flight (a boss theme playing over a field map whose own tree
  default is an ordinary town track, say) wrongly snapped back to the map's
  configured default instead of continuing what was actually playing.
  Verified against EasyRPG Player's actual C++ source: `Scene_Map::Start`
  only calls `Game_Map::PlayBgm()` (the map-tree walk) for a fresh map entry
  — resuming a save instead stops whatever's playing and replays the save's
  own remembered track verbatim, always restarted from the top. A new
  `Scene::Map#resume_saved_bgm`, called from `#initialize` in place of
  `#play_map_bgm` on Continue, plays `@state.current_bgm` (already restored
  from the save) directly, bypassing the same-file skip that would otherwise
  compare it to itself and never tell the audio backend to play anything.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks, confirmed to
  fail against the pre-fix code before the fix.
