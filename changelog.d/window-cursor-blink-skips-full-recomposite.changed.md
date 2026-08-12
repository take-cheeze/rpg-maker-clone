- **RGSS `Window#update`** no longer recomposites the whole windowskin
  (background tile, 9-slice frame, contents) every frame just to blink the
  cursor or animate the pause arrow. `window_refresh` now caches that
  background+frame+contents work in an offscreen "structural" bitmap and only
  rebuilds it when one of its inputs actually changed (skin, size, opacity,
  tone, `ox`/`oy`, or the contents bitmap being redrawn); an active window
  with nothing but a blinking cursor now costs one full-size copy plus the
  small cursor/pause blits instead of up to a dozen `Bitmap#blt` calls per
  frame. RPG2000 vehicle sprites (`Scene::Map#draw_vehicle_frame`) similarly
  skip their `Bitmap#blt` when the graphic/index/direction haven't changed
  since the last frame, matching the existing memo on the player sprite.
