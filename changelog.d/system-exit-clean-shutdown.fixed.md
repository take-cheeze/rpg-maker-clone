- **Choosing Shutdown no longer looks like a crash.** `exit` raises a
  `SystemExit`, which is an `Exception` rather than a `StandardError`, so it
  passed every `rescue` in the runtime and reached the top of the frame loop:
  the engine printed a full copy-pasteable error report and asked the player who
  had just quit to file a bug. Both the browser frame loop and the native run
  now recognise it as the game ending on purpose — the page logs `The game
  exited`, and the native build exits with the status `exit` was given instead
  of `EXIT_FAILURE`.
