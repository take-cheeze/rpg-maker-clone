- **A message line that overflows its display width is now truncated at the
  message layout's own boundary instead of bleeding onto a right-side Face
  Graphic.** `Scene::Map#draw_message_run` handed each colour run straight to
  `Bitmap#draw_text`/`#blend_text`, neither of which actually clips to the
  `w`/`h` box they're given (only ever used for centre/right alignment) — this
  looked correct in the common case purely by coincidence, since the contents
  bitmap's own right edge happened to sit exactly at the intended text
  boundary, but a right-side Face Graphic narrows that boundary by
  `FACE_SIZE + FACE_MARGIN` (52px) while leaving the bitmap itself full width,
  so an overflowing run kept drawing straight through that gap and over the
  portrait. Fixed with a new `#clip_text_to_width`, called before either draw
  path, that measures and slices a run to its own available width using the
  same `Bitmap#text_size` the layout math already trusts — making the
  no-face/left-face case correct on purpose too, not just by accident.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks, confirmed to fail
  against the pre-fix code before the fix.
