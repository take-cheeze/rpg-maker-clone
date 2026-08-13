- **A Change Encounter Rate override no longer survives a map change.**
  `Game::State#encounter_rate` (Change Encounter Rate, 11740) had no
  expiration of any kind — once set it silently overrode every future map's
  own `encount_steps` for the rest of the game, save/load included. yado.tk
  groups this together with Chipset Change, Panorama/Parallax Change and
  Tile Replacement as one family of per-map runtime overrides that reset the
  moment the party leaves and returns to a map, not just on save/load; the
  other three were already confirmed correct here, and Change Encounter Rate
  was the one still-open member of that family now that a working
  wandering-monster system exists to read it at all (`Scene::Map
  #current_encounter_steps`). `Scene::Map#perform_teleport` — the one method
  every map change (an ordinary Transfer Player, a Teleport/Escape skill,
  and by extension a same-map leave-and-return) already routes through —
  now resets `@state.encounter_rate` to `nil` there too, alongside the
  existing tileset/parallax/pan resets, so `#current_encounter_steps` falls
  back to the destination map's own tree-node setting. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
