- **Erase / Show Screen run their real transition.** The style in parameter 0
  used to be recorded and ignored: every one of them ran the same 32-frame black
  fade, including the **-1 "use the configured transition"** that is 2124 of
  Nepheshel's 2146 Erase Screens. `Game::Transition` now ports EasyRPG's
  transition model — the two parameter→style tables, each style's own length (35
  frames for a fade, 41 for the shaped ones, 1 for a cut, 0 for "none") and the
  frame-by-frame geometry — and a -1 resolves against the Change Screen
  Transitions slot, which `Game::State#seed_screen_transitions` fills in from the
  database's System settings at New Game and after a load. That command (10690)
  therefore does something at run time now instead of only being saved.
  `Scene::Map` paints the shaped transitions as a mask: the erase overlay goes
  fully opaque and the regions of the map still showing through are punched back
  out of it, which draws the blinds, the vertical / horizontal stripes and the
  border-to-centre / centre-to-border windows for real. The styles a mask cannot
  express — the scrolls and combine / division pairs (which slide the scene
  itself), zoom / mosaic / wave (which resample it) and random blocks — run as a
  fade of the correct length until the renderer can capture and transform a
  screen. Geometry pinned by new checks in `scripts/rpg2k_logic_check.rb`, the
  mask painting by `scripts/rpg2k_scene_check.rb`.
