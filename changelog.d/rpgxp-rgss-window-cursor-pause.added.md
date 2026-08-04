- **`RGSS::Window` now draws the selection cursor and pause arrow.** Building on the
  windowskin frame, `window_refresh` now also draws the blinking cursor highlight
  at `cursor_rect` (when the window is `active`) and the animated pause arrow (when
  `pause` is set), both cycled by a per-window animation counter. `Window#update`
  is native: it advances that counter and redraws — which also picks up the
  in-place `cursor_rect` mutation stock scripts do via `cursor_rect.set`.
  `cursor_rect=`, `active=`, `pause=`, `update` are now native. With this the
  menu/message/shop/battle UI renders fully — frame, text, selection cursor and
  message pause. The cursor is a stretched highlight (a crisp 9-slice is a
  refinement). See `docs/rpgxp-rgss-api-gap.md`.
