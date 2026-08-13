- RPG Maker 2000: standing on a "Hero Touch" (trigger 1) event's own tile now
  suppresses the wandering-monster random-encounter roll for that step, same
  as flying or a forced-route step. `Scene::Map#check_random_encounter`
  rolled for a fight on every ordinary step regardless of what stood on the
  landed tile; it now looks up the tile the party just landed on via
  `#event_at` and skips the roll (without accumulating that step) if the
  tile's currently active event page is Hero Touch. A same-tile Event Touch
  (trigger 2) event does not suppress it — only Hero Touch does. Covered by
  two new `scripts/rpg2k_scene_check.rb` checks.
