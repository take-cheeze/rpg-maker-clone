- RPG Maker XP projects are now tested against the genuine runtime as well as
  our own. `--rpgxp_new_game` selects New Game without input and
  `RPGXP#start_new_game` logs `[RPGXP-MAP] map=.. x=.. y=..`, the marker both
  checks assert on: `scripts/rpgxp_boot_check.bash` boots the native binary
  headlessly (wired into CI),
  and `scripts/compare-rpgxp-wine.bash` diffs our frames against the
  **genuine RGSS runtime** (`Game.exe` + `RGSS104E.dll` under wine) on the same
  key script, the RPG Maker XP counterpart of the RPG2000 wine comparison. See
  `docs/adr/0025-rpgxp-cross-runtime-testing.md`.
