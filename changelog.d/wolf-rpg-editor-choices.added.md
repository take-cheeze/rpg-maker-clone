- **WOLF RPG Editor (ウディタ/Woditor)** `Choices`(102) now really waits for
  the player: it blocks once a frame, exactly like `Wait`, polling real
  up/down/confirm/cancel input and dispatching to the chosen `ChoiceCase`/
  `CancelCase` branch (reusing `VariableCondition`'s own branch-walking
  logic). Cross-confirmed against the wolfrpg-map-parser crate's own
  `Options`/`CancelCase` structs and real `Choices` commands from the
  sample game's own map events; a left/right-key or forced-interrupt
  variant (no real example to check against) is logged and skipped rather
  than guessed, and no native choice window is drawn yet -- the same scope
  `Message`(101) already keeps. Fixed a real soak-check symptom as a side
  effect: a shop event's own "suspected infinite loop" note (a retry loop
  that previously had nothing to ever yield on) is gone. See
  `docs/adr/0070-wolf-rpg-editor-choices.md`.
