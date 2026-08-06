- **Characters sink into tall grass** — RPG2000's terrain `bush_depth`
  (下半身消去 / 半透明表示), the next field on the terrain row nothing read. The
  bottom of a character's sprite now draws at half opacity on such a tile:
  `4 - depth` as RPG_RT's divisor, so depth 1/2/3 sink the lower 10, 16 and all
  32 rows of a charset frame, at `(opacity + 1) / 2` so an already-translucent
  event wading in goes fainter still rather than snapping back to 128. The hero
  sinks unless jumping or boarded; an event sinks only on the hero's own layer
  and not mid-jump; a tile-graphic event scales the split to its own 16px frame.
  Nepheshel names four terrains after the effect — 下半身3/1消去, 下半身2/1消去,
  半透明表示, 全身半透明 — and lays two of them across **9,687 tiles of 28 maps**,
  all of which drew the hero fully opaque until now. Covered by the render,
  scene and test-bed checks. See ADR 0035.
