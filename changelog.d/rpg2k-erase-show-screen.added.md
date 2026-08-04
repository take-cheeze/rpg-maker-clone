- The **Erase Screen** (11010) and **Show Screen** (11020) event commands are
  now handled. They fade the whole screen out to black and back over a fixed
  transition, modelled on `Game::Screen` as a fade level (0 visible .. 255
  black) that eases like the tint transition and is held erased until a Show.
  Both run their transition and pause the event on the existing `:screen` wait
  until it settles, so event timing around fades is correct. The requested
  transition style (param0: 0 fade, higher = block / stripe / scroll variants)
  is recorded for fidelity but only the fade is modelled, and — like the tint
  and flash overlays — drawing the actual black overlay is the native refinement
  still to come. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
