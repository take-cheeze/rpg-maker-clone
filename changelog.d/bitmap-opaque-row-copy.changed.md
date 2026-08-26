- **Bitmap blits of opaque pixels are now row-copied instead of composed
  pixel by pixel.** `Bitmap#blt` and `#blt_quads` shared one per-pixel loop
  that re-derived the bytes-per-pixel and redid both bitmaps' bounds checks
  for every source pixel, even when the whole row was plain opaque colour --
  which chipset tiles, the map renderer's tile-cache rebuild and animation-
  step hot path, always are. When both bitmaps share a format, a row whose
  every alpha byte is 255 is now put down with one `memcpy` (the old opaque
  branch overwrote the whole pixel anyway), rows with any transparency keep
  the pixel loop, and the rect is clipped once up front instead of checked
  per pixel. A 336-tile full-grid rebuild through `#blt_quads` measured
  ~0.6ms -> ~0.02ms per pass on the host (~30x); charset-shaped blits with
  transparent margins dropped ~4x from the hoisted clipping alone. This is
  the "row-copy fast path for opaque chipset pixels" follow-up named by
  ADR 0058's on-device profiling.
