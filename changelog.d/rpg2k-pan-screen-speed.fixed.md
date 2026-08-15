- **Pan Screen now scrolls the camera at RPG_RT's real per-speed rate,
  instead of 4x too fast at every speed setting.** Confirmed against EasyRPG
  Player's source (`Game_Player::StartPan`/`ResetPan`): the real rate lives
  in a 1/16-pixel subpixel space, working out to 0.25/0.5/1/2/4/8 pixels per
  frame for speed 1 through 6 — not a flat doubling starting at a whole
  pixel. A Pan Screen command used to finish in a quarter of the real frame
  count and visibly raced across the screen instead of gliding.
