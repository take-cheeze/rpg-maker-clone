- **`RGSS::Tilemap` property holder.** `RGSS::Tilemap` is no longer an empty stub:
  it now stores the properties `Spriteset_Map` drives — `tileset`, the seven
  `autotiles[0..6]` slots, `map_data`/`flash_data`/`priorities` (`Table`s),
  `ox`/`oy`, `visible`, `viewport` — with RGSS defaults, so the stock map scene can
  build, scroll and dispose its ground layer without raising. The native autotile
  assembly + priority-layering render is still future work; see
  `docs/rpgxp-rgss-api-gap.md`.
