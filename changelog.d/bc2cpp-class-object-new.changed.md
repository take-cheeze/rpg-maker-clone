- bc2cpp builds a `klass.new` whose callers all pass class constants as one direct construction per class, so five more
  `initialize` entries (`Game::Screen`, `Game::MoveRoute`, `Game::Picture`, `RPG2k::Scene::Title`,
  `LCF::SaveTyped::Record`) leave the closed host method table.
