- **WOLF RPG Editor (ウディタ/Woditor)** map events now run: page
  selection (the last page whose every enabled condition holds), Auto/
  Parallel pages stepped every frame, and Confirm/Player-Touch/Event-Touch
  pages started on a decision-key press or a movement bump, freezing hero
  movement while a non-Parallel page (or an auto-run Common Event) is
  executing. Previously every map event was parsed but inert. Event
  movement (move routes) is not implemented yet, so events stay at their
  starting position. See `docs/adr/0066-wolf-rpg-editor-map-events.md`.
