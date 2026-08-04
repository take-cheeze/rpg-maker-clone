- **Pan Screen** (11060) event command is now handled, completing the
  tint/shake/flash/pan screen-effect family on `Game::Screen`. Its four
  operations map to the state machine: **lock** / **unlock** freeze or resume the
  camera following the hero, and **pan** / **reset** scroll a pixel offset toward
  a target (distance in tiles, speed 1–6). `Scene::Map` holds the camera where
  locking began while locked and adds the pan offset to it, so — like the shake —
  the pan is **visible** with the current renderer. The pan/reset scroll honours
  the wait flag via the shared `:screen` wait (lock/unlock are instant). The
  per-frame scroll rate is an approximation of RPG_RT's. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
