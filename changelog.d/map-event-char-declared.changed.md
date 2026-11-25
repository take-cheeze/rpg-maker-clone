- A map event's state record now takes its `Game::Character` when it is
  built, so the bc2cpp declarations name `@char` as `Game::Character`. The
  compiled map scene drops about 100 nil tests on event characters, and Wio
  flash shrinks.
