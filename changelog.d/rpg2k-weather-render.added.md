- `Scene::Map` now renders the map weather effect (Change Weather / 11070): a
  screen-sized overlay draws animated rain streaks or drifting snow, with the
  particle count scaling to the weather strength, so the type/strength already
  held on `Game::State` become visible on the map instead of only round-tripping
  through the save.
