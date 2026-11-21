- bc2cpp: declared keyword parameters (`k: T`, `?k: T` with an Integer, Float,
  Symbol, Array, Hash, String or program-class type) are checked where the
  method reads the given value and typed in its body. `Game::States.prune`'s
  `keep:` and `Scene::Battle#battle_list_window`'s four keywords are declared;
  `desc.to_s` becomes a direct call.
