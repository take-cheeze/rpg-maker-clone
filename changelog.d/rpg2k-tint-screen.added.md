- **Tint Screen** (11030) event command is now handled (the Ruby half). A new
  `Game::Screen` on `Game::State` models the screen tint as RPG2000's four
  0..200 channels (red / green / blue / saturation) and interpolates them toward
  the command's target over its duration — the classic
  `cur += (target - cur) / frames_left` step that lands exactly on the last
  frame — advanced once per frame by `Scene::Map`. The command's wait flag pauses
  the interpreter (a new `:screen` wait) until the transition settles. Applying
  the tint as an `RGSS::Viewport` tone is the native (C++) work still to come, so
  it does not yet change what is drawn. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
