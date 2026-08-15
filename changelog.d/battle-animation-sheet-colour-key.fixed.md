- **A battle animation's `Battle/<name>` sheet is now loaded colour-keyed**,
  instead of opaque. `Bitmap.new`'s second argument maps palette index 0 to
  transparent (`mruby-rgss/src/lib.cxx`'s `load_xyz_mem` /
  `load_png_tolerant_mem` `trans` flag), and `Scene::Map#animation_sheet` was
  the one sheet loader in the RPG2000 runtime that never passed it — CharSet,
  ChipSet, FaceSet, Monster, System and Picture all did. An animation sheet is
  a 5-column grid of 96x96 cells whose *entire* background is the transparent
  colour, so every cell `#blit_animation_cell` laid down painted an opaque
  96x96 rectangle of that background over its target: a solid block sitting on
  the enemy for the animation's whole duration rather than a spell. Confirmed
  against EasyRPG's own material table (`src/cache.cpp`, fetched verbatim),
  whose `Spec::transparent` column is true for `Battle` — alongside every
  other directory this runtime already colour-keys — and false only for the
  four full-screen backdrops (`Backdrop`, `Panorama`, `Title`, `GameOver`),
  which this runtime already loads opaque and which stay that way. Covered by a
  new `scripts/rpg2k_scene_check.rb` check (the sheet loads as
  `Battle/<name>` with the transparency flag set, and `Backdrop/` still loads
  without it), which required teaching the check suite's stub `Bitmap` to
  record how a graphic was loaded, not only that it was.
