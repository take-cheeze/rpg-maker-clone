- bc2cpp now emits guarded direct calls for proven RGSS `Sprite#bitmap=` and
  five-argument `Bitmap#fill_rect` sites through frame-independent native
  entry points; unsupported receiver classes and overloads retain Ruby dispatch.
