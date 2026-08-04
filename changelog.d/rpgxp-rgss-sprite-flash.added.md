- **`RGSS::Sprite#flash` is now rendered.** `Sprite#flash(color, duration)` runs a
  timed pulse: a colour flash overlays that colour into the sprite's pre-composite
  at an alpha that fades over the duration, while a nil-colour "empty" flash blinks
  the sprite out and back in. `Sprite#update` decays the flash one frame at a time
  and clears it when the duration runs out. This was the last stored-but-ignored
  Sprite property, so the battle hit-flash, dying-blink and animation flashes now
  actually show. Also finishes wiring `Sprite#bush_depth=` natively (it was being
  shadowed by a stray Ruby `attr_writer`). See `docs/rpgxp-rgss-api-gap.md`.
