- **bc2cpp trace host**: the headless Nepheshel host no longer paces frames to 60 fps (`NO_RENDER_WAIT`), and
  `BC2CPP_CLOSED_OPTIMIZE=1` builds the closed library without enable_debug's -O0, so the pair can time and profile
  the compiled RPG2000 engine. See `docs/bc2cpp-trace-host.md`.
