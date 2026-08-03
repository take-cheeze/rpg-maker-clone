- **Shake Screen** (11050) event command is now handled — and, unlike the tint,
  it is **visible** with the current renderer. `Game::Screen` gains a timed
  shake: a float-free triangle-wave horizontal offset (amplitude scaled by the
  command's power, rate by its speed) that `Scene::Map` subtracts from the camera
  each frame, so the whole view shakes and settles back to centre when the timer
  runs out. The wait flag pauses the interpreter (the shared `:screen` wait, now
  gated on `Game::Screen#busy?`) until the shake ends. The oscillation is an
  approximation of RPG_RT's shake. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
