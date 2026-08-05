- **The RGSS script host now drives the game's blocking main loop one frame at a
  time via a Fiber.** When `RGSS_SCRIPT_HOST` is on, `RPGXP` runs the bundled
  scripts' `Main` (`$scene.main while $scene`) inside an mruby `Fiber` and wraps
  `Graphics.update` to `Fiber.yield` once per frame, so `RPGXP#main_loop` advances
  exactly one game frame per call — which lets the web build's per-frame
  `emscripten_set_main_loop` callback keep control each frame instead of hanging on
  the scripts' blocking loop. The scripts run unmodified and no Asyncify is needed.
  It was gated behind the `RGSS_SCRIPT_HOST` flag when it landed and drives every
  boot now that the host is the default; `mruby-fiber` is added to the build. See
  `docs/adr/0023-rpgxp-script-host-frame-driver.md`.
