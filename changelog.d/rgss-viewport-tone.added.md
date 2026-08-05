- **`RGSS::Viewport#tone` is drawn — the screen tint works.** VX / VX Ace tint
  the map with `@viewport1.tone.set($game_map.screen.tone)`, and the RPG2000 side
  has wanted the same per-pixel pass for as long (`docs/TODO.md` records an
  earlier attempt that never reached the display). Unlike `Viewport#color`, a
  tone cannot be one more layer on top: it **rescales what is already drawn**
  (desaturate toward luminance, then offset each channel). So instead of an
  overlay, every display object in a viewport folds the viewport's tone into its
  own composite as the last step:
  - `Sprite` and `Plane` already baked their own tone into a scratch buffer, so
    the viewport's is applied there after the sprite's tone, colour and flash —
    matching RGSS, which tints the viewport's *contents*, not its sources.
  - `Tilemap` gets a pass over its composed ground and priority "above" canvases,
    so a tinted map tints its roofs too.
  - The per-pixel maths moved into one shared `apply_tone_px`, so the three
    composites cannot drift apart — and the RPG2000 tint can adopt it rather than
    growing its own.
  The viewport re-composites its children when the tone changes, checked from
  `#update` as well as on assignment because the stock scripts mutate the Tone
  **in place** (`viewport.tone.set(...)`) and call `update` every frame. The
  re-composite is skipped unless the value actually moved, so a static map costs
  one comparison a frame.
  Not covered, and written up in
  [`docs/rpgvx-rgss-api-gap.md`](docs/rpgvx-rgss-api-gap.md): `Window` contents
  (a different composite path — and RGSS puts windows in their own viewport, so a
  map tint does not tint the message window anyway).
