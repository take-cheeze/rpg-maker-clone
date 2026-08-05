- MZ (M6.3c): RPG Maker MZ now boots past the loading scene to **`Scene_Title`
  and walks its start map**. `MZ#main_loop` advances the game by pumping the
  JavaScript host once per frame instead of calling `SceneManager.update`
  itself: MZ hands its loop to PIXI's ticker, so only a pumped
  `requestAnimationFrame` both updates *and* renders the scene, and only a
  pumped frame delivers the asynchronous image/font/config/storage loads
  `Scene_Boot` polls — without which the boot could never leave the loading
  screen. `MZ::HOST_GLOBALS_JS` also aliases `HTMLImageElement` to the host's
  own `Image`, so PIXI v5 recognises loaded bitmaps as image sources instead of
  wrapping them into broken textures.
- MZ: the native Canvas2D context gained `strokeRect`. MV never calls it, but MZ
  strokes an item-background frame for every row of every selectable window
  (`Window_Selectable.drawBackgroundRect` → `Bitmap.prototype.strokeRect`), so
  building the title's command window threw `TypeError: not a function` on the
  first drawn frame. It is drawn as four `lineWidth`-thick bars through the same
  native fill, sharing `fillRect`'s transform, alpha and composite handling.
- MZ: `data/mz-sample` is now authored by `scripts/gen-mz-sample.py` (as the MV
  bed is) and carries what MZ's scenes require — real terms, a tileset,
  `MapInfos`, a walled 17×13 room with a parallel test event, a party sprite,
  and the system art MZ asserts on: an `img/system/ButtonSet.png` at least 11 ×
  48 px wide (`Sprite_Button.checkBitmap` throws below that) and a tileset whose
  `flags[0]` carries `0x10`, "no effect on passage", without which the empty
  upper tile layers make every cell passable and no wall blocks.
- MZ: new `--mz_new_game`, `--mz_move_test` and `--mz_screenshot` flags (mirroring
  the MV ones, with `MV::JS.screenshot_gl` capturing the WebGL frame), and
  `scripts/mz_boot_check.bash` now drives New Game → map → a held direction and
  fails unless the run reports `[MZ-MAP]` and `[MZ-MOVE] moved=true`. The new
  blocking `scripts/mz_testbed_check.rb` validates an MZ project's boot-critical
  data and system art under plain CRuby — no build, no JS engine, no GPU — and
  is equally useful pointed at a real MZ game.
