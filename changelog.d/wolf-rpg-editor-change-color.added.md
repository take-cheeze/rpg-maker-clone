- **WOLF RPG Editor (ウディタ/Woditor)** `ChangeColor`(151) now tints the
  whole screen: an animated tone transition (WOLF's own absolute 0-200
  RGB scale, 100 neutral, mapped onto native RGSS `Viewport#tone`, linear
  over a real number of frames — this reader's first "N-frame screen
  animation") or, when its own "flash" flag is set, a one-shot overlay via
  native `Viewport#flash`. Cross-confirmed against the wolfrpg-map-parser
  crate's own `ChangeColor` struct and all 10 real calls in the sample
  game, including its documented "reset"/"pitch black" UI presets showing
  up verbatim in real data. See
  `docs/adr/0079-wolf-rpg-editor-change-color.md`.
