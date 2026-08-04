- **`RGSS::Window` property holder.** `RGSS::Window` is no longer an empty stub:
  it now stores the properties every `Window_Base` subclass drives — `windowskin`,
  `contents`, `cursor_rect`, `x`/`y`/`width`/`height`, `ox`/`oy`,
  `opacity`/`back_opacity`/`contents_opacity`, `visible`, `z`, `active`, `pause`,
  `stretch`, `viewport` — with RGSS defaults, so the stock menu/message/shop/battle
  windows construct, configure and draw into their `contents` without raising. The
  native frame/cursor/pause compositing is still future work; see
  `docs/rpgxp-rgss-api-gap.md`.
