- **In the browser** the game screen is now scaled up by the page rather than by
  the engine. The canvas keeps the game's own resolution (320x240 for
  RPG2000/MV, 640x480 for XP) and `src/shell.html` gives the element its
  on-screen size in CSS — the whole-number zoom the screen has room for, filling
  the width when it is narrower than that, with `image-rendering: pixelated` for
  the same nearest-neighbour look. LVGL's window zoom only enlarged the SDL
  window, so the software renderer stretched every frame on the CPU and handed
  the canvas four times the pixels at 2x; the browser now does that upscale
  instead. The screen is the same size as before at every width that fits it,
  and a screen too narrow for 1:1 now fits the viewport instead of overflowing
  it. SDL's pointer coordinates are game pixels as a result — which is what the
  MV/MZ `TouchInput` bridge already assumed (`src/sdl_input.cxx`).
