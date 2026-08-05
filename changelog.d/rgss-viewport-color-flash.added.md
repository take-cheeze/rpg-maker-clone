- **`RGSS::Viewport#color` and `#flash` are drawn.** RPG Maker VX / VX Ace do
  every screen effect through the viewport rather than a sprite overlay — the
  fade is `@viewport3.color.set(0, 0, 0, 255 - brightness)`, the flash is
  `@viewport2.color`, and battle/skill animations call
  `viewport.flash(color, duration)` — so with `Viewport` carrying no colour at
  all, none of it reached the screen. It is now native (`mruby-rgss`): a colour
  overlay canvas the size of the viewport, held above its content layer, with a
  timed flash composited over the base colour and faded out linearly. The
  overlay is repainted from `Viewport#update`, not only on assignment, because
  the stock scripts mutate the colour **in place** (`viewport.color.set(...)`)
  and call `update` every frame; the fill is skipped unless the effective colour
  or the viewport size actually changed. This is the same "screen-sized colour
  at an opacity" mechanism ADR 0021 measured working for the RPG2000 fade, moved
  into the viewport so it clips, scrolls and hides with it — and available for
  the RPG2000 side to adopt in place of its own overlay sprite.
- `RGSS::Viewport#tone` is **kept but not drawn**, and says so once. Unlike a
  colour, a tone rescales what is already drawn (desaturate toward luminance,
  then offset each channel), so it needs a per-pixel pass over the viewport's
  contents rather than one more layer on top — the same native work the RPG2000
  screen tint is waiting on. Holding the value keeps a script's bookkeeping
  consistent and makes the tint land the moment that pass exists. The measured
  state of the whole RGSS2/RGSS3 surface is tracked in
  [`docs/rpgvx-rgss-api-gap.md`](docs/rpgvx-rgss-api-gap.md).
