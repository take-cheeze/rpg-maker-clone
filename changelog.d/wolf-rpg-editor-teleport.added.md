- **WOLF RPG Editor (ウディタ/Woditor)** `Teleport`(130) now moves the hero
  to a new map/position, rebuilding the entire running map scene (tileset,
  event sprites, both viewports) once every Common Event for the current
  frame has finished running. Moving another event or a party member
  instead of the hero remains unimplemented, since it needs persistent
  per-map event state (switches/variables/moved events surviving a
  revisited map) this reader does not have at all — real sample-game data
  uses exactly that case in all 5 of its own calls, so none of them are
  covered by this pass, but the hero case is the semantic most real WOLF
  games use this command for. Cross-confirmed against the wolfrpg-map-
  parser crate's own `TransferCommand`, correcting its own mislabeled `-1`
  target sentinel against the manual and this reader's own already-
  cross-confirmed target convention (`SetMoveRoute`/`SetVariableEx`). See
  `docs/adr/0080-wolf-rpg-editor-teleport.md`.
