- MV canvas path fill (`Bitmap.drawCircle`, snow weather, vector shapes): the
  Canvas2D bridge now builds a polygon from `beginPath`/`moveTo`/`lineTo`/`arc`/
  `rect` and scanline-fills it on `fill()` — these were all no-ops, so anything
  drawn as a path rendered nothing. Most visibly, `Bitmap.drawCircle` (which MV's
  `Weather` uses to draw snow particles, and many plugins use for UI) produced a
  blank bitmap; snow now renders. Arcs tessellate to segments and the fill honors
  the current transform, `globalAlpha` and composite mode via the shared blend
  path (new native `__mv_canvasFillPolygon`). Solid `fillStyle` only; `stroke`,
  `clip` and multi-subpath remain no-ops (no core MV consumer). Unit-tested in
  `mruby-mvjs/test/canvas_test.rb` (triangle fill, circle fill, transformed
  fill).
