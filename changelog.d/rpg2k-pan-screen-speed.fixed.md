- **Pan Screen now scrolls the camera at RPG_RT's real per-speed rate,
  instead of 4x too fast at every speed setting.** Confirmed against genuine
  RPG_RT.exe under wine: timing a real, already-authored Pan Screen against
  Nepheshel's own map at its stock speed and again with only the speed
  parameter edited showed the real rate lives in a 1/16-pixel subpixel space,
  working out to 0.25/0.5/1/2/4/8 pixels per frame for speed 1 through 6 —
  not a flat doubling starting at a whole pixel. A Pan Screen command used to
  finish in a quarter of the real frame count and visibly raced across the
  screen instead of gliding.
