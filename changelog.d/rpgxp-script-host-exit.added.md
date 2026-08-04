- **`Kernel#exit` is now provided for the RGSS script host.** The stock RMXP
  `Interpreter` calls `exit` to abort on runaway common-event recursion; the
  `mruby-exit` core gem is now in the build, so that raises a catchable
  `SystemExit` which the script-host driver ends the game on (rather than a
  `NoMethodError`). The per-frame driver also idles cleanly after the host game
  ends, so the web build's callback no longer falls into the built-in tick with no
  scenes. See `docs/rpgxp-rgss-api-gap.md`.
