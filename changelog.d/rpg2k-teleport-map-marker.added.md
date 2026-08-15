- **`Scene::Map#perform_teleport`** (the single choke point for Transfer
  Player, Teleport, Recall to Location, and a Teleport/Escape skill's own
  warp) **now logs the same `[RPG2k-MAP] map=… x=… y=…` marker**
  `RPG2k#start_new_game`/`#continue_game` already emit once on the initial
  map load — a play session that walks through several map changes after
  that now has a marker per change instead of only the first, useful for
  matching a screenshot's location back to the actual map file and tile
  while debugging. Existing `[RPG2k-MAP]`-scraping tooling
  (`scripts/rpg2k_boot_check.bash`, `scripts/compare-nepheshel-save-wine.bash`)
  is unaffected: one only checks the marker's presence, and the other's
  `tail -1` never crosses a teleport in the sequence it scripts.
