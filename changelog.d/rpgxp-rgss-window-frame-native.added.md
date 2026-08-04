- **`RGSS::Window` now draws its windowskin background and frame.** Building on the
  native contents render, `window_refresh` now composites the windowskin when one
  is set: it stretches the 128×128 background tile over the window at
  `back_opacity` and draws the 64×64 frame as a 9-slice (16px corners) at
  `opacity`, then blits the contents on top — so framed menu/message/shop/battle
  windows render, not just their text. `windowskin=`, `opacity=`, `back_opacity=`
  are now native (they trigger a refresh); the compositing reuses the tested
  `Bitmap#stretch_blt`/`#blt`. The blinking cursor rect and the pause arrow (which
  need per-frame animation) remain stored-only. See `docs/rpgxp-rgss-api-gap.md`.
