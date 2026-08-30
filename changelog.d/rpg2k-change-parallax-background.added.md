- RPG Maker 2000: the **Change Parallax Background** event command (11720) now
  swaps a map's panorama at runtime. The interpreter records a
  `Game::State#parallax` override — the `Panorama/<name>` image plus the
  horizontal / vertical loop and autoscroll (enable + speed) settings, matching
  a reference implementation's parameter order (ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine) — and raises a one-shot rebuild request
  the map scene polls (`take_parallax_request`) to tear down and recreate the
  parallax sprite mid-map. `Scene::Map#setup_parallax` now prefers the override
  over the map's own panorama fields, and the override is dropped on the next map
  change (like shown pictures), so a teleport restores the destination map's own
  backdrop. Covered by new `scripts/rpg2k_logic_check.rb` checks.
