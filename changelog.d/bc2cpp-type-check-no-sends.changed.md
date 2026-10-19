- Skip the by-name send ranking in the `bc2cpp-build` type-check step
  (`--no-sends`): it only affects reporting, not pass/fail, and shortens the
  run. Full ranking remains available by running the check without the flag.
