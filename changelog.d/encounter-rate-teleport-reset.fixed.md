- **A Change Encounter Steps (11740) override no longer survives leaving and
  returning to a map.** `Scene::Map#perform_teleport` already reset the
  sibling per-map overrides on a Teleport (Chipset, Panorama, Pan/camera lock,
  the hero's forced-route Change Graphic) but had no equivalent reset for
  `Game::State#encounter_rate`, so a Change Encounter Steps command issued on
  one map silently kept overriding `#current_encounter_steps` on every map
  visited afterwards instead of yielding back to that new map's own
  `encount_steps` — a real, reachable divergence now that random
  ("wandering-monster") encounters read `encounter_rate` at all. Fixed by
  clearing it in `#perform_teleport`, the single call site for both an
  ordinary Transfer Player and a queued Teleport/Escape field-skill warp; the
  value still round-trips through save/load undisturbed, matching yado.tk's
  distinction between "resets on leaving-and-returning to the map" (Chipset/
  Panorama/Encounter Steps/Tile Replacement) and "resets on save/load" (a
  separate, narrower list this is not part of). Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code before the fix.
