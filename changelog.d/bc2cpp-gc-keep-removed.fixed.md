- **bc2cpp**: compiled code no longer reuses an object the GC has already freed after `Array#pop`, `Array#shift` or
  `Hash#delete`. The removed value lived only in a C local, which the GC does not scan, so the next allocation could
  sweep it. `LRUBitmapCache#[]` re-inserted a swept Bitmap this way, and maps 194 and 355 hit a GC assertion when a
  save file was present. The generated code now roots each removed value in the GC arena, as it roots a new object.
