- **WOLF RPG Editor (ウディタ/Woditor)** `Effect`(290) now applies its
  Picture-target `DrawPositionShift`(123 of 279 real occurrences, by far
  the largest single combination) and `ColorCorrect`(14) effects — an
  instant coordinate nudge and an additive RGB tint, both applied across a
  real contiguous range of picture numbers, hooking directly into the
  already-tracked `Picture`(150) sprite's own position and native RGSS
  color. Cross-confirmed against the wolfrpg-map-parser crate's own
  `EffectCommand::Base`/`PictureEffectType`, and the sample game's own
  real data (including a store-display Common Event's own six-picture
  `ColorCorrect` call). The Character and Map targets, and every other
  Picture effect kind, remain unimplemented — the manual's own
  Character-target list runs to roughly two dozen entries the crate's own
  4-value enum predates. See
  `docs/adr/0077-wolf-rpg-editor-effect-command.md`.
