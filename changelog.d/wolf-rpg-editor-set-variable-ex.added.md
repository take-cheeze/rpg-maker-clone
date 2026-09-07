- **WOLF RPG Editor (ウディタ/Woditor)** `SetVariableEx`(124) now answers its
  Character-state queries: standard/precise position, numpad direction, and
  event id, for any map event, "this event", or the hero (the same target
  convention `SetMoveRoute`(201) already uses). Cross-confirmed against the
  wolfrpg-map-parser crate's own `SetVariablePlusCommand`/`CharacterField`
  structs and the sample game's own real data, including its random-
  encounter check's use of the hero's precise position. Its map-tile,
  Picture-number, and "other" (map id/BGM-BGS/mouse) query kinds remain
  unimplemented. Along the way, fixed a real, previously-dormant crash in
  `SetVariable`(121)'s own division/modulo assignment operators
  (`Integer#zero?`, a method this project's vendored mruby fork does not
  have), surfaced by extracting the shared assignment-operator logic and
  exercising it against the sample game's own real `DivideEquals` call.
  See `docs/adr/0074-wolf-rpg-editor-set-variable-ex.md`.
