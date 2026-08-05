- MZ (M6.3c): `MV::JS.present_gl(bitmap, handle)` copies a WebGL context's
  rendered frame (its FBO, read back top-down RGBA8 via the new
  `mv_webgl_pixels` accessor over the surfaceless-EGL backend) onto an on-screen
  `RGSS::Bitmap`, swapping R/B for the LVGL ARGB8888 surface — the native core of
  the MZ on-screen present, the WebGL counterpart to `MV::JS.present`'s Canvas2D
  path (both now share one copy helper). `gl_test` covers it end to end: clear a
  WebGL canvas green, present its FBO onto a Bitmap, and read the pixel back.
  The mz.rb per-frame present loop and input that build on this follow.
