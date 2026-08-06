- **A status condition can drain HP as the party walks**, RPG2000's field
  poison. The `situation` row's `hp_change_map_steps` / `hp_change_map_val` pair
  (and the matching SP pair) were parsed and read by nothing, so an ailment that
  is *defined* as wearing the party down between fights did nothing outside
  battle. `Game::State` now counts walked tiles and `Game::Party#apply_map_step_
  damage` drains every afflicted member each time the count reaches a multiple of
  that state's own interval, summing when two states slip on the same step. The
  drain **cannot kill** — it floors at 1 HP, which is why nothing on this path
  needs the game-over re-check the event commands that damage the party do — and
  a member already down slips nothing. `Scene::Map` counts a step for the
  player's own movement and for a forced move route, but not for a teleport
  (the party arrives without walking), and flashes the screen red when a step
  drains, since the map shows no HP for the loss to be visible on.
