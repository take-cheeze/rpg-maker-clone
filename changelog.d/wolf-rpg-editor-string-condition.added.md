- **WOLF RPG Editor (ウディタ/Woditor)** `StringCondition`(112),
  `VariableCondition`(111)'s string-comparison counterpart, is now
  implemented (`Equals`/`NotEquals`/`Includes`/`StartsWith` against a
  literal or another string variable), cross-validated against the
  wolfrpg-map-parser crate's own dedicated struct and 33 real calls in the
  sample game. See
  `docs/adr/0091-wolf-rpg-editor-string-condition.md`.
