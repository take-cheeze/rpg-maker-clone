- RPG Maker **XP**: the actor EXP curve and the **Change EXP** (315) command, and
  **Change Level** (316) is now EXP-aligned. `RPGXP::Game::Actor` builds its
  `exp_list` with the exact RMXP formula — `exp_list[L] = exp_list[L-1] +
  Integer(exp_basis * (L + 3) ** pow / 5 ** pow)`, `pow = 2.4 +
  exp_inflation / 100` — ported from the editor's default `Game_Actor` script
  (extracted from a real `Scripts.rxdata`). Setting EXP re-derives the level:
  climbing while the next threshold is met (learning each level's class skills as
  it passes) and dropping while below the current one (skills are kept on the way
  down), then re-clamping HP/SP; Change Level realigns EXP to the target level's
  threshold (RMXP's `level=`). The level and EXP round-trip through the Marshal
  save. Covered by new `mruby-rpgxp/test` cases — the curve matched against a
  reference computation, Change EXP levelling up and back down, and Change Level's
  EXP alignment — and the `rpgxp_testbed_check` harness still builds a
  `Game::Actor` for every actor in the real XP test bed. Change Parameters (317,
  permanent stat deltas) is the remaining Change-Actor command.
