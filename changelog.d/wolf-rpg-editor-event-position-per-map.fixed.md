- **WOLF RPG Editor (ウディタ/Woditor)** a revisited map (`Teleport`(130)
  or `SaveLoad`(220)'s own Load) now correctly finds its own events
  exactly where they were left, instead of colliding with a different
  map's identically-numbered event — `Wolf::Interpreter#event_position`
  now keys by `[current_map_id, event.id]` rather than `event.id` alone.
  See `docs/adr/0089-wolf-rpg-editor-event-position-per-map.md`.
