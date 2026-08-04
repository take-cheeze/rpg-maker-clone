- MV menu smoke test: a new `--mv_menu_test` flag drives the MV sample past New
  Game onto the map, opens the party menu the way the engine does — setting
  `Scene_Map`'s own `menuCalling` flag so its `updateCallMenu` runs the real
  `callMenu` (→ `SceneManager.push(Scene_Menu)`) inside the scene loop — then
  logs `[MV-MENU] reached_menu=<bool>` and captures a frame. It exercises the
  menu path every RPG uses (map → `Scene_Menu` → the command/status windows), so
  CI confirms the menu opens and renders. Wired as a non-blocking `build` job
  step alongside the existing MV boot/play/battle/movement/message smokes.
