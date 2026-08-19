- **The F9 debug menu's Map viewer no longer stalls on open, especially under
  the `--sixel`/`--iterm` terminal backends.** It drew its whole-map minimap
  one `set_pixel` native call per tile -- up to ~58,000 calls on a single
  full-viewport refresh, cheap enough under SDL to pass unnoticed but slow
  enough on top of the terminal backends' own per-frame PNG/sixel encode cost
  to look like a hang, and it repeated on every frame while a pan key was
  held. It now collapses each row's same-passability tiles into one
  `fill_rect` run instead of one call per tile.
