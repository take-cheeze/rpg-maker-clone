- **A battle animation cell's four `tone_*` fields are now honoured**,
  closing the gap cycle #222's own zoom fix deliberately left open ("Per-cell
  tone remains unimplemented ... needs `Bitmap#tone_blt` over a cached,
  re-toned sheet copy"). `battle_anime` chunk 19's per-cell fields 6-9
  (`tone_red`/`tone_green`/`tone_blue`/`tone_gray`,
  `mruby-lcf/mrblib/schema.rb`, each defaulting to 100/neutral) decode the
  same 0..200 shape `Game::Picture`'s own `red`/`green`/`blue`/`saturation`
  carry, and were confirmed dropped by grepping every reference to those
  four field names across `mruby-rpg2k`: zero hits outside the schema
  before this fix. New `Scene::Map#animation_cell_tone`/
  `#toned_animation_cell?` read the four fields (defensive `respond_to?`
  guards matching `#animation_cell_opacity`/`#animation_cell_zoom`'s own
  shape). `#toned_animation_cell_src` crops a cell's raw 96x96 sheet square
  into a small reused scratch buffer and `Bitmap#tone_blt`s it into a
  second, cached bitmap — mirroring `#toned_picture_src`'s existing
  cache-a-toned-copy shape for Show Picture, sized down to one cell instead
  of a whole picture since a cell's sheet is shared across many cells. The
  result is cached in a new bounded `@animation_tone_cache`
  (`ANIMATION_CELL_TONE_CACHE_MAX = 16`, the same eviction shape
  `@picture_tone_cache` already uses), keyed by sheet identity + cell id +
  tone rather than name since a cell has no name of its own.
  `#blit_animation_cell` reaches for the toned copy only when a cell's tone
  differs from neutral; the untouched common case (no author-set tone)
  blits straight from the sheet exactly as before. The saturation-channel
  sign flip `#toned_picture_src` already applies for Show Picture's
  `saturation` field is carried over to the cell's `tone_gray` field
  **unconfirmed** for this specific field — asserted only by analogy to the
  already-established Picture behaviour, not independently verified against
  genuine RPG_RT under wine (documented directly in
  `toned_animation_cell_src`'s own comment). Covered by new
  `scripts/rpg2k_scene_check.rb` checks (the field-by-field default/absent
  cases; a drawn cell staying on the raw-sheet `#blt` path when untoned,
  switching to a distinct cached, cropped-and-toned bitmap once toned, and
  reusing that cache on a repeat draw).
