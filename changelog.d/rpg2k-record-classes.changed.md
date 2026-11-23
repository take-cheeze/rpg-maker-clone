- **rpg2k**: interpreter call-stack frames (`Game::Interpreter::Frame`), the
  foreground execution snapshot (`Game::State::ForegroundExec`) and Parallel
  Process entries (`Scene::Map::Parallel`) are small classes instead of
  Symbol-keyed Hashes. Saves are byte-identical.
