- **Loading a save no longer leaves a stray window/sprite from the scene it
  was opened over.** `RPG2k#continue_game` and `#start_new_game` replaced
  `@scenes` with the new `Scene::Map` after disposing only `@scenes.last`,
  unlike `#return_to_title` / `#show_game_over`, which already dispose every
  scene in the stack. Loading from the title screen's Continue (stack
  `[Title, SaveLoad]`) dropped the `Title` scene's command window and
  background sprite without disposing them, leaving them drawn on top of
  every later scene, including a subsequent `RPG2k::Scene::Battle`. Loading
  mid-battle via the Open Load Menu event command (stack
  `[Map, SaveLoad]`, RPG2003's 5001) dropped the old `Scene::Map` instead,
  so its live `@battle` was never disposed either, orphaning the whole
  battle UI. Both methods now dispose every scene in `@scenes` before
  swapping in the loaded map, matching `#return_to_title`.
