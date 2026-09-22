- bc2cpp: a MONO-devirtualized call (a bare method name with exactly one
  compiled definition anywhere in the program) into a class whose ivars are
  embedded in a real struct now checks the receiver's runtime class before
  calling the compiled body directly, falling back to ordinary dynamic
  dispatch otherwise. A call whose real receiver answers through
  `method_missing` (`LCF::Array1D`/`Sections`'s own schema-field access) was
  invisible to that "exactly one definition" count and could reach the
  compiled accessor with a receiver that was never that owner, dereferencing
  `DATA_PTR` on an object with no matching struct -- a real, reproduced crash
  on `Game::Actor#faceset_index`, and already live (unexercised by
  `Game::Actor` specifically not being wired) on `Game::ChipSet#terrain`.
