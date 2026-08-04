- `RGSS::Bitmap#tone_blt(src, tone)` — copy a bitmap applying an `RGSS::Tone`:
  desaturate toward luminance by `gray` (0..255), then add the per-channel
  offsets (-255..255), leaving alpha untouched. This is the native half that
  Tint Screen needs and the screen fade/flash did not: a tone rescales what is
  already drawn, so unlike those it cannot be had by compositing a solid colour
  on top. It writes to a separate destination rather than transforming in place,
  so repeating it is idempotent — a caller that redraws a layer only when it
  changes would otherwise re-tint an already-tinted layer every frame.
  Nothing consumes it yet; see `docs/TODO.md` for what is left to wire it into
  `Scene::Map`.
