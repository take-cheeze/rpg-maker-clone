- The map scene now stores its `Game::Map` before its first call on itself,
  so the bc2cpp declarations name the scenes' `@map` as `Game::Map`, with no
  nil. The compiled map scene drops its nil tests on the map, and Wio flash
  shrinks.
