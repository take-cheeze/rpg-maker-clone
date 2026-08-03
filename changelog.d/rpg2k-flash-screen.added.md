- **Flash Screen** (11040) event command is now handled (the Ruby half),
  completing the tint/shake/flash trio on `Game::Screen`. A flash stores a colour
  and a strength that fades linearly to zero over the command's duration
  (advanced each frame by `Scene::Map`), and the wait flag pauses the interpreter
  on the shared `:screen` wait — now gated on `Game::Screen#busy?` covering tint,
  shake **and** flash — until it fades out. Like the tint, drawing the
  full-screen colour overlay at its strength needs the pending native
  alpha-blend/viewport support, so the flash does not yet change what is drawn.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
