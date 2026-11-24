- An RPG2000 window now creates its skin and cursor bitmaps before its first
  call on itself. The bc2cpp declarations name them as `RGSS::Bitmap`, now
  that a declaration may name a native class. The compiled engine drops the
  nil tests on both, and Wio flash shrinks.
