- **bc2cpp closed build:** engine natives written in C++ (`mruby-rgss`, `mruby-lcf`) are now also called without a
  frame when their body reads it only through the argument readers; the host sweep's framed calls fall from 1.78M to
  0.71M (`LCF#cp932_to_utf8`, `Bitmap#blt_quads`, `RGSS#to_nfd`).
