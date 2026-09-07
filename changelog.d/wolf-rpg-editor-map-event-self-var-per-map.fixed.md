- **WOLF RPG Editor (ウディタ/Woditor)** a map event's own self-variables
  are now also keyed per map (`VarStore#map_event_self_bank`, alongside
  `Wolf::Interpreter#current_map_id`), closing the one gap the per-map
  event-position fix left open — two different maps' own event id spaces
  both start from small numbers like 0/1/2 and would otherwise collide.
  See `docs/adr/0090-wolf-rpg-editor-map-event-self-var-per-map.md`.
