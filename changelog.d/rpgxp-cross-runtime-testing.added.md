- RPG Maker XP projects are now tested in every runtime they can run in.
  `--rpgxp_new_game` selects New Game without input and `RPGXP#start_new_game`
  logs `[RPGXP-MAP] map=.. x=.. y=..`, the marker all three checks assert on:
  `scripts/rpgxp_boot_check.bash` boots the native binary headlessly (wired into
  CI), `scripts/rpgxp_browser_check.py` plays the project in the **browser
  build** by feeding the emscripten page's own loader a zip of it and driving
  headless Chromium over the DevTools protocol (Python standard library only —
  no npm dependency; also wired into CI, with the frames uploaded as an
  artifact), and `scripts/compare-rpgxp-wine.bash` diffs our frames against the
  **genuine RGSS runtime** (`Game.exe` + `RGSS104E.dll` under wine) on the same
  key script, the RPG Maker XP counterpart of the RPG2000 wine comparison. See
  `docs/adr/0025-rpgxp-cross-runtime-testing.md`.
