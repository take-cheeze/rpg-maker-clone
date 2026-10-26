- bc2cpp caches a bare constant read whose one binding is not a class (`CLK_3`, `FOREVER_CLOCK`, and any other single
  assignment), not only class and module constants, so the lookup runs once per site instead of on every read.
