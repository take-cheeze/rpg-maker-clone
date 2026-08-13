- MZ: partially-transparent pixels (window corners, any anti-aliased sprite
  edge) no longer render over-bright. `UNPACK_PREMULTIPLY_ALPHA_WEBGL` — which
  PIXI sets on every ordinary texture upload (`BaseTexture`'s default
  `alphaMode` premultiplies on upload, and its `NORMAL` blend mode assumes
  that happened) — was silently swallowed, since GLES has no equivalent pixel
  store parameter. Textures now upload with their colour channels correctly
  premultiplied by their own alpha whenever the flag is set, on all four
  texture upload paths (raw `ArrayBufferView` and canvas-source, for both
  `texImage2D` and `texSubImage2D`).
