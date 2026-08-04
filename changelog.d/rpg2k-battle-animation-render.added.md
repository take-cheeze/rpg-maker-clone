- **Battle animations now play on the map.** Show Battle Animation (11210)
  previously only *timed* the event; it now draws the animation too. `Scene::Map`
  builds a frame-by-frame player from the database `battle_anime` entry: it loads
  the `Battle/<name>` cell sheet, resolves the target character's position (the
  player, the running event, or a map event by id), and each animation frame
  (held ANIM_CELL_FRAMES) composites that frame's visible cells from the sheet's
  96×96 grid over the target on a screen-high layer above the hero, firing the
  **screen flashes** its timings request through the shared `Game::Screen` flash.
  When the animation or its sheet is missing it degrades to the previous timed
  wait, so a cutscene paces correctly either way. Per-cell zoom / tone /
  transparency and non-screen (target-only) flashes are approximated / deferred
  for now. Covered by a new check in `scripts/rpg2k_scene_check.rb` (the animation
  sprite shows while playing, a flash timing fires, and the sprite hides and the
  event resumes when it finishes).
