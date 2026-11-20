- **bc2cpp**: `sig/bc2cpp/declarations.rbs` declares `Game::TextReveal`'s `@pauses` / `@speeds` / `@instants` as
  Arrays of their markers and `Scene::Map#troop_ids` as returning an Array, all checked at runtime. The closed build
  has 7 fewer by-name owner calls in mruby-rpg2k.
