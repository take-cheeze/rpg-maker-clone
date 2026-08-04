- **Parallax backgrounds** — RPG2000 maps now draw their `Panorama/<name>`
  backdrop behind the tile layers instead of leaving the void. `Scene::Map`
  composites the image into a screen-sized sprite at `z = -1`, and the new
  `Game::Parallax` module computes the per-axis draw offset (a port of EasyRPG
  Player's parallax model): a looping axis tiles the image and scrolls it at
  half the camera rate with optional autoscroll (`parallax_sx`/`parallax_sy`),
  while a non-looping axis anchors it — fixed to the screen for a full-screen
  backdrop, panned across its excess for a larger image. Validated against the
  real Nepheshel game (all 45 parallax maps' images resolve and every offset
  stays in range across a camera sweep) and pinned by
  `scripts/rpg2k_render_check.rb` / `scripts/rpg2k_scene_check.rb`.
