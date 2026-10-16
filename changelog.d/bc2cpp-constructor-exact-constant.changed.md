- **bc2cpp** (ADR 0313 addendum): a `Klass.new` whose constant is proven is an entry of that class's `initialize`
  only, so `Game::Map.new` no longer widens `RPG2k::Scene::Map#initialize`'s argument pools (and every `@state`
  stored from them) to `LCF::MapUnit|Game::State`.
