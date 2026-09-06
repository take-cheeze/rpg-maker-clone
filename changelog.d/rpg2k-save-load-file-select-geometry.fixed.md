- **RPG2000 save/load file-select screen** (`Scene::SaveLoad`) now matches the
  genuine RPG_RT.exe layout measured under wine: the three slot boxes start
  8px below the header (y=40/104/168, the up arrow living in that strip)
  instead of butting against it; a flat field backdrop is painted behind the
  screen so the title picture no longer shows through when opened from
  Continue; the header prompt is windowskin-blended system text (swatch 0)
  instead of flat white; the "File N" label is the term at x=0 plus the number
  right-aligned to x=63 under a fixed 63px cursor; and the level/HP line puts
  `LV`/`HP` at x=0/42 in swatch 1 with the right-aligned values at x=12/54 in
  swatch 0 (was x=4/46, all one colour). Covered by new checks in
  `scripts/rpg2k_scene_check.rb`.
