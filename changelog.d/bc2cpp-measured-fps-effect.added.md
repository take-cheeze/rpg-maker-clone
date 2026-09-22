- Docs: recorded the first real, linked-build measurement of bc2cpp's
  devirtualization effect (`docs/profiling.md`), built and run under
  `RPGMAKER_BC2CPP=1` via `xvfb-run` against the Nepheshel New Game repro.
  `scene.update` (the per-frame mruby interpreter/game-logic section) drops
  ~48%, total frame work ~29%, reproduced across two independent trials --
  closing the "not measured, needs a real build" caveat every bc2cpp ADR in
  this series repeated. A smaller, single-sample counter-datum (the one-time
  New Game transition construction cost) is also reported rather than
  omitted, with a follow-up noted.
