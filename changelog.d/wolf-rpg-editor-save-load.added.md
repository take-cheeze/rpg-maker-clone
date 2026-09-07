- **WOLF RPG Editor (ウディタ/Woditor)** `SaveLoad`(220) — "保存・読込"
  — now saves and loads a deliberately partial snapshot (regular/system
  variables and strings, plus the current map and hero position),
  reusing `Teleport`(130)'s own scene-rebuild request and dropping every
  active Common Event/map event Run so nothing keeps running past a
  Load, matching the manual's own documented guarantee. Self-variables,
  the database, and party state are not captured. See
  `docs/adr/0087-wolf-rpg-editor-save-load.md`.
