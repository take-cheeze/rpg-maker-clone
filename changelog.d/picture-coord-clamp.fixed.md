- **Show/Move Picture** clamps every picture value to +-1,048,575 (a pixel
  position from an RPG2003 variable can reach +-9,999,999), so its 1/1024
  fixed-point form and a move's interpolation fit a 32-bit integer on every
  build instead of overflowing on the 32-bit no-bigint Wio build. The drawn
  zoom is capped at 100,000%.
