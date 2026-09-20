- bc2cpp now uses `Game::Actors#existing`'s `Game::Actor` return hint to
  specialize downstream actor calls with a runtime class guard and Ruby
  fallback.
