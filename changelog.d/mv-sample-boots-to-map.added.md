- MV boots without complete art, and the committed sample now reaches its map.
  MV's `Scene_Boot` reserves system images (`img/system/Window.png`, …) and
  blocks on `ImageManager.isReady()` until they load, so a project missing that
  (optional) art — like the deliberately asset-free `data/mv-sample` — stalled
  in `Scene_Boot` forever. A missing/undecodable image now resolves as a 1×1
  transparent bitmap (via `onload`) instead of erroring, so the boot proceeds
  and absent art simply draws nothing (`drawImage` clamps out-of-range reads).
  A new `--mv_new_game` flag auto-selects **New Game** once the title appears,
  so the CI smoke test drives the sample past the title into `Scene_Map`
  (`[MV] scene: Scene_Boot → Scene_Title → Scene_Map`) and captures the
  in-game frame. Covered by `mruby-mvjs/test/canvas_test.rb`.
