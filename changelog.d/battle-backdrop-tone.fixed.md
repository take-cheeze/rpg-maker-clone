- **Battle backdrop now receives Change Screen Tone.** `Scene::Map#update_map_tone`
  pushes the map layer's tone onto the live battle backdrop (`@battle.apply_backdrop_tone`)
  every time the tint changes, and `Scene::Battle#build_battle_back` seeds the
  freshly built sprite from `Scene::Map#current_map_tone`, so a Tint Screen
  active during a fight tints what is actually on screen instead of only the
  (hidden) map layer. RPG_RT tints the battle background — confirmed against
  EasyRPG Player's `Spriteset_Battle::Update` (`background->SetTone(...)`) —
  so this port now matches. Covered by a new `scripts/rpg2k_scene_check.rb`
  check.
