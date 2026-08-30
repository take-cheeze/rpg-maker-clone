- **The battle background is actually visible now.** RPG2000's battle backdrop
  was resolved from the game's own data correctly (`Game::Backdrop`'s map-tree
  walk over `backdrop_type`, falling back to the terrain the encounter started
  on) and then drawn *behind the map*: real RPG_RT replaces the map scene with
  a battle scene outright, but this port runs the fight inline on `Scene::Map`,
  whose `#render` kept compositing the tile layers, the parallax, the hero and
  the events every frame — and the backdrop sprite's z 5 (matching a reference
  implementation's own background-priority constant, correct there precisely
  because no map is ever drawn
  beside it — not independently confirmed against genuine RPG_RT under wine)
  is outranked by both `@map_viewport` (z 100) and `@upper_viewport`
  (z 200), whose lower tile layer is opaque. Every fight was therefore fought
  over whatever chip layer the party happened to be standing on, with the
  chosen `Backdrop/<name>` image completely hidden. Both viewports are hidden
  for the fight's whole duration now (`Scene::Map#set_map_layers_visible`) and
  the tile / parallax / character compositing is skipped outright rather than left
  running under a hidden layer — the same treatment `#render` already gives the
  picture layer — then both un-hide and redraw on the first frame after the
  battle UI clears. The in-battle Show Battle Animation is deliberately not
  gated: it renders through a top-level sprite (z 150, above the battlers), not
  through the map viewports. Covered by a new check in
  `scripts/rpg2k_scene_check.rb` (the map draws normally before the fight, is
  hidden and stops compositing the instant the battle screen is up, and is back
  the instant the fight ends), confirmed to fail against the pre-fix code.
