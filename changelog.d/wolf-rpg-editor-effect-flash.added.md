- **WOLF RPG Editor (ウディタ/Woditor)** `Effect`(290)'s Picture-target
  `Flash` now reuses native RGSS `Sprite#flash` for a one-shot decaying
  colour overlay. Wiring it up found a pre-existing gap: `ChangeColor`
  (151)'s own "flash" case never called `Viewport#update`, so it would
  freeze at full intensity forever instead of fading — fixed alongside.
  See `docs/adr/0084-wolf-rpg-editor-effect-flash.md`.
