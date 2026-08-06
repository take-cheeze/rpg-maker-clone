- **A forced player route walks the party instead of teleporting it.**
  `step_player_route` wrote the destination tile straight onto the state, so a
  cutscene walking the hero across a room moved it a tile at a time while the
  same hero, walking on input, interpolated smoothly. The party now slides
  through the step, sharing the machinery ordinary walking already used, and a
  forced **jump** arcs the hero exactly as it arcs an event.
- A step in progress has to land before the next begins, which also caps a
  forced route at the walking pace it is drawn at. Proceed With Movement drives
  the slide itself, since the normal movement step is skipped while it waits.
