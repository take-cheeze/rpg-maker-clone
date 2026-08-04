- **Tint Screen now darkens the view.** The Tint Screen (11030) command already
  drove a `Game::Screen` tone state machine; the darkening half of it now draws.
  `Scene::Map` overlays a black screen sprite (below the flash / fade overlays)
  whose opacity approximates how far the tone's channels average below neutral
  (100), so a night / cave tint visibly dims the map the way RPG_RT does, and a
  neutral tone clears it. A full tone — the colour cast, brightening above
  neutral, and saturation — needs native per-pixel tone and is still to come.
  Covered by a new check in `scripts/rpg2k_scene_check.rb` (a black tint drives a
  near-opaque overlay, a partial tint a partial one, and a neutral tint clears
  it).
