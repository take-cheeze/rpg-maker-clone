- **Title BGM no longer bleeds into the next scene.** Confirming a title
  command (New Game, Continue, or Shutdown) left the title BGM playing under
  the map/load screen; `Scene::Title` now calls `Audio.bgm_stop` before
  dispatching the selection, matching RPG_RT.
