- The scenes' `@state` is now declared `Game::State`, with no nil. The
  state-less scenes (Title, Game Over, and Save/Load, which keeps its state in
  `@game_state`) answer the Change System SFX lookup themselves. The compiled
  engine drops about 330 nil tests, and Wio flash shrinks.
