- **Shake Screen now moves the camera with the same waveform, amplitude and
  per-frame smoothing as EasyRPG Player's real C++ source**, instead of a
  hand-rolled triangle-wave approximation. Verified against EasyRPG's actual
  `src/shake.h`/`src/game_interpreter.cpp` rather than guessed at:
  `Game::Screen#update_shake` (`mruby-rpg2k/mrblib/game.rb`) used to scale
  amplitude by `power * 2` and sweep a triangle wave with no smoothing at
  all, when real RPG_RT's `Shake::NextPosition` uses `amplitude = 1 + 2 *
  power` (a 1px base amplitude even at power 0 — a "power 0" shake is not
  flatly inert), samples a genuine sine wave, and separately caps each
  frame's *step* off the previous frame's own offset
  (`(speed * amplitude) / 8 + 1`). Ported using `Math.sin` directly
  (`mruby-math` is already in this build's gem set, and `Scene::Map`'s
  enemy-levitate flying offset already calls it the same way). Covered by
  new `scripts/rpg2k_logic_check.rb` checks, including one that
  independently re-derives EasyRPG's formula and compares it frame-by-frame
  against the engine's own output; two
  pre-existing checks that had baked in the old, incorrect amplitude/
  zero-power assumptions are corrected alongside it.
