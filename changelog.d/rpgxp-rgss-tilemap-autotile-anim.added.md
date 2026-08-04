- **`RGSS::Tilemap` autotiles now animate.** An autotile bitmap wider than one
  96px frame holds several animation frames; `Tilemap#update` (now native) advances
  a counter whose frame index is `counter / 16` mod 4 — matching RMXP/mkxp's
  16-ticks-per-frame `atAnimation` timing — and the renderer shifts the autotile
  source into the current frame's column, so water and waterfalls animate instead
  of freezing on frame 0. The per-frame work is skipped except on a frame boundary,
  and entirely when the map has no animated autotile. See
  `docs/rpgxp-rgss-api-gap.md`.
