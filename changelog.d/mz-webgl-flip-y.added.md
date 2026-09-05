- MZ: `UNPACK_FLIP_Y_WEBGL` is now genuinely honoured rather than silently
  swallowed (GLES has no equivalent pixel-store parameter), reversing a raw
  or canvas-sourced texture upload's row order the same way a real browser
  would, on all four texture upload paths (raw `ArrayBufferView` and
  canvas-source, for both `texImage2D` and `texSubImage2D`) — the same
  CPU-side-transform-before-upload approach already used for
  `UNPACK_PREMULTIPLY_ALPHA_WEBGL`, applied before it so both flags can be
  set together. No real MZ release driven through the engine so far has ever
  set this flag `true` (a stock PIXI v5 build never does), so this is
  spec-completeness rather than a fix for observed breakage.
