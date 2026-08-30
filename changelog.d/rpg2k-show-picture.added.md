- **Show Picture** — the RPG2000 Show / Move / Erase Picture commands
  (11110/11120/11130) now display `Picture/<name>` images over the map. A
  `Game::Picture` per shown id (held on `Game::State`) carries its centre
  position, zoom, opacity, tone and scroll-with-map flag, decoded with a
  parameter layout ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine (literal or variable-sourced
  coordinates, transparency → opacity). **Move Picture** eases every parameter to its target
  over the command's duration, and its wait flag suspends the interpreter (a
  new `:picture` wait) until the move settles; **Erase Picture** removes it.
  `Scene::Map` composites the pictures id-ordered — scaled by `stretch_blt`, at
  their opacity — into a layer above the map and below the message window.
  Grounded in the real Nepheshel game (all 104 Show Picture commands' images
  resolve, ids and zoom in range) and covered by `scripts/rpg2k_logic_check.rb`
  (Picture interpolation + the three commands) and `scripts/rpg2k_scene_check.rb`
  (a picture renders and its move advances under the scene loop). Picture tone
  is carried but not yet drawn (it needs the same native tone support as the
  screen tint).
