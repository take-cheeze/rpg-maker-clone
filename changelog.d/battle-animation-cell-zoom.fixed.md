- **A battle animation cell's own `zoom` is now honoured**, instead of every
  cell being blitted at its sheet's native 96x96. The LCF `battle_anime`
  schema (`mruby-lcf/mrblib/schema.rb`, chunk 19's per-cell field 5, schema
  default 100) has always decoded the field, and
  `Scene::Map#blit_animation_cell` has always ignored it — the same gap its
  own `transparency` field had before `battle-animation-cell-transparency`
  closed it (that fragment's own note flagged zoom and tone as still
  "approximated as a plain blit, unchanged"). A new
  `Scene::Map#animation_cell_zoom` reads the field as a percentage (100
  unscaled, clamped to 0 at the bottom so a corrupt negative value cannot ask
  for an inverted rect), and `#animation_cell_dest_rect` scales the cell's
  96x96 source square by it, centred on the same placement pixel the unzoomed
  path already centres on — the identical "position/size by centre"
  convention `Scene::Map#draw_picture`'s own `pic.zoom` already established
  for Show Picture. `#blit_animation_cell` keeps the cheap, unchanged `Bitmap
  #blt` path for the common case (zoom at its schema default of 100) and only
  reaches for `Bitmap#stretch_blt` — already used for Show Picture's own zoom
  — once a cell actually asks for a different size. Per-cell tone remains
  unimplemented. Covered by new `scripts/rpg2k_scene_check.rb` checks (the
  percentage-to-scale math including the defaulted and clamped cases; a drawn
  cell staying on the plain `#blt` path at 100%, and taking the `#stretch_blt`
  path at 200%/50%, landing at the doubled/halved size still centred on the
  same pixel).
