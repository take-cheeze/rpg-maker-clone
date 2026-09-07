- **WOLF RPG Editor (ウディタ/Woditor)** `Picture`(150) now shows real
  **file** pictures (every filename already carries its own `Data/`-
  relative subfolder, e.g. `"SystemFile/TitleGraphic.png"`, with
  sprite-sheet division/pattern cropping for animated character
  graphics) and the manual's own documented "hidden feature" procedural
  shapes (`<SQUARE>`, `<GRADX-.../<GRADY-...>` gradients, `<LINE>`) a
  window-type picture's string can name instead of a real file --
  confirmed to be exactly what the sample game's own entirely
  custom-drawn menus use for their boxes/gradients/dividers, alongside
  the text pictures added previously. Move now updates transform only,
  without re-reading content. A real window-skin file, `<CIRCLE>`/
  `<TRI-*>`, and any call whose argument count doesn't match the
  confirmed layout remain explicit no-ops. See
  `docs/adr/0068-wolf-rpg-editor-picture-files-and-shapes.md`.
