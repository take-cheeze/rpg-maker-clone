- Drive a real RPG2003 project into an actual fight headlessly via a new
  `--rpg2k_battle_troop <id>` flag (RPG Maker 2000/2003): New Game, then open a
  battle against the named database troop on the map's own interpreter once the
  map is up, logging the fight as `[RPG2k-BATTLE]` when its UI is really on
  screen (ADR 0053 Phase 3). The 2003 test beds ship no encounters, so a bare
  boot only ever reached the map; this is the first end-to-end drive of the
  2003 battle path against real data -- scene routing to
  `RPG2k3::Scene::Battle`, troop sprites, actor sprites, the gauge-card status
  layout and the per-frame gauge advance. `scripts/rpg2k_boot_check.bash` now
  runs this pass (mtf-meido-action, troop 14) alongside the map boot, asserting
  the marker and a battle scene that never raised.
- The battle-drive exposed a latent native-only crash: `Scene::Battle` seeded
  its backdrop from `Scene::Map#current_map_tone` behind a `respond_to?` guard
  that CRuby honours (private methods answer false) but mruby does not, so
  **every** native battle raised `NoMethodError: private method ...` at
  `#build_battle_back` -- only the CRuby harnesses passed. `current_map_tone`
  is now genuinely public, the way its own comment and the "services the battle
  scene calls back into" list already intended.
