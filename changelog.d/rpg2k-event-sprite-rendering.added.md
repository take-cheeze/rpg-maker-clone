- **RPG2000 event sprite rendering** — map events now draw their real graphic
  instead of a red marker. `Scene::Map` blits each event's `CharSet/<name>`
  character frame (facing row + walk-pattern column) or, for a tile-substitution
  event (empty CharSet name), a 16×16 chipset tile via the new
  `Game::ChipsetLayout.event_tile_rect`. Events composite into the correct
  layer relative to the hero — below, above, or the same layer y-sorted
  around him — and a translucent page is drawn at half opacity.
  `Game::EventGraphic` selects the drawn frame from the page's animation type
  (walk-while-moving, continuous, fixed-direction, fixed-graphic and spin)
  and converts the page's LCF facing (0..3) to the runtime numpad convention
  so events face the right way. Validated against the real Nepheshel game
  (every one of its 15,881 charset-event pages resolves to a CharSet file and
  its tile-substitution ids land in-bounds) and pinned by
  `scripts/rpg2k_render_check.rb` and `scripts/rpg2k_scene_check.rb`. ADR
  0021's later side-by-side comparison against a genuine RPG_RT.exe under
  wine confirmed this event-sprite compositing pixel-identical on real
  Nepheshel maps too.
