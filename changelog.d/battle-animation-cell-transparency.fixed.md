- **A battle animation cell's own `transparency` is now honoured**, instead of
  every cell being blitted fully opaque. The LCF `battle_anime` schema
  (`mruby-lcf/mrblib/schema.rb`, chunk 19's per-cell field 10 — liblcf's
  `rpg::AnimationCellData::transparency`, an `int32_t` defaulting to 0) has
  always decoded the field, and `Scene::Map#blit_animation_cell` has always
  ignored it: an animation whose author faded a cell in or out, or layered a
  translucent glow over a solid one, played every frame at full strength — a
  visibly different animation, not a subtler one. A new
  `Scene::Map#animation_cell_opacity` converts the field's 0-fully-opaque..100-
  fully-invisible percentage to RGSS's 0..255 opacity exactly the way a
  reference implementation's own animation-drawing code does (ported from
  that source, not independently confirmed against genuine RPG_RT under
  wine): `255 * (100 - cell.transparency) / 100`, integer division and all,
  and that opacity is passed straight to `Bitmap#blt`, which already blends in
  straight (non-premultiplied) alpha, so a half-transparent cell lands in the
  animation bitmap at half coverage with its colour intact rather than dragged
  toward black. A fully transparent cell is skipped outright rather than run
  through the blit's own per-pixel loop to draw nothing, and a cell carrying no
  `transparency` at all (the schema default, a bare test double) reads as 0 and
  draws exactly as it did before. Out-of-range values are clamped both ways.
  Per-cell zoom and tone remain approximated as a plain blit, unchanged. Covered
  by new `scripts/rpg2k_scene_check.rb` checks (the percentage-to-opacity math
  including the defaulted and out-of-range cases; a drawn cell blitting at its
  own opacity, in the same place as before, and a 100%-transparent one laying
  down nothing).
