- **`Bitmap#blt_quads(x, y, src, quads)`** batches a whole tile's source
  rects into one native dispatch: each `quads` element
  `[qdx, qdy, sx, sy, w, h]` composites exactly as an individual full-opacity
  `#blt` would (the pixel loop is shared with `#blt`, so the two cannot
  drift; the mruby-rgss test asserts pixel equality per quad, including a
  clipped quad and partial-alpha blending). The map renderer's `draw_tile`
  now issues one call per tile instead of one dispatch plus a `Rect`
  allocation per sub-quad — and animation steps redraw every animated cell,
  so this was the renderer's hottest mruby path. On the Android test device
  the intro map's animation-step `map.layers` spikes dropped from ~57-86ms
  to 30-54ms (cluster ~37-41ms), with fps at 42-45 on the same scene.
