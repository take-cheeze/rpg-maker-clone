- **bc2cpp** passes a `Rect.new(x, y, w, h)` whose only use is the rect
  argument of `Bitmap#blt`, `#stretch_blt` or `#copy_blt` as its four fields
  instead of allocating an `RGSS::Rect` (the window cursor, frame and
  background, list arrows, battle gauges and digits, and actor faces).
  `BC2CPP_STACK_RECT=0` turns it off.
