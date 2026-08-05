- `scripts/compare-rpgxp-wine.bash` takes a `STEPS_SPEC` environment variable
  that replaces its built-in key script (`'title -;newgame Return;op Return*6'`).
  The default steps walk around the start map, which never reaches an opening
  cutscene — the part of a real game where pictures, tints and forced move routes
  actually run, and so the part worth diffing against the genuine runtime.
