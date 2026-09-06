- **The browser build's on-screen FPS/CPU overlay under-reported CPU usage**
  (e.g. showing ~50% while the tab itself was at 100%) and had no way to turn
  it off during normal play. Both were true because it used LVGL's stock
  `LV_USE_PERF_MONITOR` behaviour unmodified: the CPU% only measures time
  spent inside LVGL's own render step, which is a fraction of a real frame
  here since Ruby game logic and input polling run outside of it
  (`docs/profiling.md`). It now reads from a custom idle measurement
  bracketing the whole per-frame call instead (`src/main.cxx`,
  `include/lv_conf.h`), and **F3** toggles the overlay on/off
  (`src/sdl_input.cxx`) — not bound to anything else in the browser build.
