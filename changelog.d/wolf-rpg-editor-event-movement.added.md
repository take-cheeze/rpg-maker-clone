- **WOLF RPG Editor (ウディタ/Woditor)** map events now move: a page's own
  `move_type` (None/Custom/Random/TowardHero) and the explicit
  `SetMoveRoute`(201) "■動作指定" event command both play back real
  RouteCommand steps -- move/face in the four cardinal directions, turn,
  random movement, and approaching or fleeing the hero -- against a runtime
  position kept separate from the parsed map data, targetable at any event
  or the hero per the manual's own documented target encoding. Only the
  RouteCommand ids this reader could cross-check against the editor's own
  "動作指定" window are implemented; ids found in the sample game's own data
  that no independent source could place are logged and skipped rather than
  guessed. See `docs/adr/0069-wolf-rpg-editor-event-movement.md`.
