- MV sample message/menu boxes now render as framed boxes. `gen-mv-sample.py`
  authors a plain blue windowskin (`img/system/Window.png`, hand-encoded) — a
  solid background quadrant and a lighter 9-slice frame quadrant — which every
  `Window_Base` draws from. Previously, with no windowskin, message boxes showed
  bare text over the map; now they render as an actual blue box with a border,
  exercising the engine's `Window` 9-slice `blt` path. Completes the visible
  sample alongside the tileset and character sprite.
