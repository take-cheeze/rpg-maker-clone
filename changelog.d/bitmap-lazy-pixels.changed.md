- **Bitmaps** made with `Bitmap.new(width, height)` allocate their pixels on the
  first draw or read, so a map layer that is deferred straight away never holds
  them (about 336 KB less at every map setup on the Wio Terminal).
