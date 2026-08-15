- **In the browser** the game screen is now scaled up by the page rather than by
  the engine. The canvas keeps the game's own resolution (320x240 for
  RPG2000/MV, 640x480 for XP) and `src/shell.html` gives the element its
  on-screen size in CSS — a whole-number zoom that shrinks to fit a narrow
  screen, with `image-rendering: pixelated` for the same nearest-neighbour look.
  LVGL's window zoom only enlarged the SDL window, so the software renderer
  stretched every frame on the CPU and handed the canvas four times the pixels
  at 2x; the browser now does that upscale instead. What the page shows is
  unchanged, and SDL's pointer coordinates are now game pixels — which is what
  the MV/MZ `TouchInput` bridge already assumed (`src/sdl_input.cxx`).
