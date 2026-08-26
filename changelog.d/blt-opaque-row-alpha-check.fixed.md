- **`Bitmap#blt`/`#blt_quads`'s row-copy fast path no longer mistakes a
  partially-transparent row for a fully opaque one.** The scan that decides
  whether a source row can be `memcpy`'d straight across stopped as soon as it
  found *one* pixel with alpha 255, instead of confirming every pixel in the
  row was opaque, so a row with both opaque and transparent pixels (exactly
  what an autotile quarter-tile's diagonal corner mask looks like) got copied
  verbatim — pasting the transparent pixel's raw, typically black, source
  bytes over the destination instead of leaving it alone. This is what made
  chipset autotile corners render as black instead of blending. Covered by a
  new `mruby-rgss/test/test.rb` case that blits a mixed-alpha row and asserts
  the transparent pixel leaves the destination untouched.
