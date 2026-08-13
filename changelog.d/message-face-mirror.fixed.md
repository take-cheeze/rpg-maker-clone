- **Change Face Graphic's mirror flag now actually flips the portrait.**
  `Game::MessageConfig#face_flipped` (param2) was already read, stored and
  persisted through the save, but `Scene::Map#draw_message_face` never
  consulted it — every face drew unmirrored regardless. `RGSS::Bitmap#blt`
  has no flip of its own (`mruby-rgss`'s own `Sprite#mirror=` resorts to the
  same per-pixel software pass, for the same reason), so a new
  `#build_face_cell` crops the selected 48x48 cell out of the FaceSet sheet
  once, at message-open time — a single blit normally, or 48 single-column
  blits in source-column-reversed order when mirrored — into a small
  dedicated bitmap `#draw_message_face` then draws unconditionally, instead
  of re-deriving the crop rect from the raw sheet on every reveal frame.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks (an unmirrored
  face crops in one blit from the right cell; a mirrored one crops in 48,
  with the sheet's leftmost/rightmost source columns landing on the
  destination's rightmost/leftmost columns), both confirmed to fail against
  the pre-fix code before the fix.
