- **WOLF RPG Editor (ウディタ/Woditor)** now shows and erases pictures via
  its `Picture`(150) command -- the single command the bundled "RPG Basic
  System" uses to draw everything visible (message windows, choices, its
  whole menu), since the editor has no native widget for any of it. The
  mode bitmask (show/move/erase, five display kinds, blend, anchor, zoom
  mode) is fully decoded and cross-confirmed against two independent
  sources; rendering works for "string as picture" text pictures (real
  position, opacity, zoom, angle, blend), with file- and window-based
  pictures still explicit no-ops. See
  `docs/adr/0067-wolf-rpg-editor-picture-command.md`.
