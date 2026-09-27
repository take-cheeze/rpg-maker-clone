- bc2cpp's closed-world resolver now devirtualizes traced exact-class calls to
  inherited methods when the complete, mixin-free lookup chain proves the
  target, while retaining a runtime class guard and dynamic fallback.
