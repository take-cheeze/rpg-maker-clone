- **The debug editors' key-binding hint line no longer runs off the right
  edge of the screen.** `Scene::MapViewer`'s Edit mode hint ('Arrows:Move
  C:Paint CTRL:Pick SHIFT:Layer R:Save B:Exit') is wider than the 320px
  screen at the game's own font, and `Bitmap#draw_text` neither wraps nor
  clips its own text (see `Scene::Base#clip_text_to_width`'s own comment on
  that), so the tail of the line used to draw straight past the bitmap's
  right edge and simply vanish there rather than appear. `Scene::Base` gained
  `#wrap_text_to_width`/`#draw_wrapped_hint`, a generic word-wrap over
  `Bitmap#text_size`; both `Scene::MapViewer` and `Scene::ChipsetEditor`'s
  footers now wrap onto multiple lines instead. `MapViewer::FOOTER_H` grew to
  two lines' worth (reserved for every mode, so the viewport doesn't resize
  when switching modes); `ChipsetEditor::FOOTER_H` grew to match, though its
  footer already had enough slack below the grid either way.
