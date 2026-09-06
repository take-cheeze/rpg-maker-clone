- **The browser build now shows a live FPS/CPU overlay** in the canvas's
  top-right corner, using LVGL's built-in performance monitor — the same one
  the Android build already draws. A browser tab has no title bar or terminal
  to read `--profile`'s stderr output from, so this is the only on-screen way
  to see frame rate there (`include/lv_conf.h`).
