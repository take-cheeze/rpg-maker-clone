- **RPG Maker MZ** now proves the rest of its in-game paths headlessly, not
  just the boot and a walked map: `--mz_message_test` shows a message through
  `$gameMessage` and reports whether `Window_Message` opened, `--mz_menu_test`
  opens the party menu through `Scene_Map`'s own `callMenu` and reports whether
  `Scene_Menu` was reached, `--mz_save_test` round-trips a save through the real
  `DataManager` — MZ's save path is a **promise chain** (JSON → pako →
  localforage), so the probe starts it and polls until it settles, then re-enters
  the map the way `Scene_Load` does — and `--mz_battle_test=<troopId>` starts a
  battle with a Battle Processing command run through the map interpreter and
  reports whether `Scene_Battle` was reached. `scripts/mz_boot_check.bash` gained
  an `MZ_MODE` (`play`/`message`/`menu`/`save`/`battle`) that drives each one and
  asserts its success line, and CI runs all five against `data/mz-sample`.
