- **WOLF RPG Editor (ウディタ/Woditor)** the `9100000`/`9180000`/`9190000`
  variable-reference addressing ranges (a map event's, the hero's/a party
  member's, or "this event"'s own position/facing, get or set through the
  ordinary variable mechanism) are now partly implemented: plain tile X/Y,
  precise (half-tile) X/Y, and numpad-convention facing read or write a
  real position; pixel height, shadow number, pixel offset, and character-
  chip image stay unimplemented (each needs sub-tile pixel/shadow/image
  state this reader has never tracked). See
  `docs/adr/0100-wolf-rpg-editor-position-addressing.md`.
