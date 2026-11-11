- **bc2cpp closed build:** engine natives written in C++ (`mruby-rgss`, `mruby-lcf`) are now also called without a
  frame when their body reads it only through the argument readers; the host sweep's framed pushes fall from 5.55M to
  4.50M (`LCF#cp932_to_utf8`, `Bitmap#blt_quads`, `RGSS#to_nfd`).
