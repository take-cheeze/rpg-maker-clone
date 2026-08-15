- **The PSP EBOOT now also starts RPG Maker XP and VX/VX Ace games,** not
  just RPG2k. `app/psp/main.cxx` detects which maker's project (if any) is
  present at its fixed Memory Stick install location the same way
  `src/main.cxx` does for desktop (`is_rpgvx_game`/`is_xp_game`), constructs
  the matching class (`RPG2k`/`RPGXP`/`RPGVX`) and drives its per-frame
  `#main_loop`. Doing this correctly required creating the LVGL display at
  each maker's own *native* resolution (RPG2k 320×240, XP 640×480, VX/VX Ace
  544×416) rather than the panel's fixed 480×272 — `RGSS::Graphics.width`/
  `height` and everything a game draws derive directly from the display's
  own resolution, so creating it at the panel's would have silently
  distorted every game's coordinate math (this was a latent bug even for
  RPG2k, invisible until now since CI has never had a real project to
  exercise it against). RPG XP and RPG VX/VX Ace's native resolutions both
  exceed the panel in *both* dimensions (they were designed for a desktop
  window), so `mruby-rgss/src/psp.cxx`'s flush callback now centers the
  logical canvas on the panel and clips every row to its actual bounds
  instead of writing out of the framebuffer's allocation — for RPG2k that is
  plain letterboxing, for XP/VX a same-scale, centered window onto the
  game's own screen (content outside it still runs correctly but is not
  drawn; real scaling is future work, see `app/psp/README.md`'s "Not yet
  wired").
