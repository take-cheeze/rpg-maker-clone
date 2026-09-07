- **WOLF RPG Editor (ウディタ/Woditor)** `Effect`(290)'s Character-target
  `Flash`/`Shake` now reuse the same mechanics as their Picture-target
  namesakes, resolved to the hero's or an event's own live sprite (via
  `SetMoveRoute`(201)/`SetVariableEx`(124)'s own already-cross-confirmed
  target convention) instead of a picture number. See
  `docs/adr/0086-wolf-rpg-editor-effect-character.md`.
