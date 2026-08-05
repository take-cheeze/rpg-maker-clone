- MZ (M6.3c): RPG Maker MZ now takes input. `MZ#main_loop` syncs the engine's
  held keys and pointer into MZ's `Input`/`TouchInput` each frame before
  `SceneManager.update` — `sync_input` writes `RGSS::Input`'s pressed virtual
  buttons into `Input._currentState`, and `sync_touch` feeds the mouse into
  `TouchInput`. rmmz's `Input`/`TouchInput` share rmmv's virtual-button names and
  state shape, so the key map and bridge are reused from MV
  (`MV.pressed_buttons` / `MV.touch_bridge_js`, which read only `RGSS::Input`).
  Together with the on-screen present, MZ now boots, renders and responds to
  input through the WebGL renderer.
