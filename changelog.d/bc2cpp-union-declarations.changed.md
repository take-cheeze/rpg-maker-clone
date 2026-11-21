- **bc2cpp**: a union declaration of program classes (`A | B`, `nil | A | B`, or a class with subclasses
  standing for its closed subtree) is now runtime-checked on every store or method entry and seeds the class
  pools, so a send on such a receiver becomes one direct call per class with no owner-call fallback.
  `Game::MoveRoute`'s `world` parameter is declared `RPG2k::Scene::MapWorld | RPG2k::Scene::VehicleWorld`,
  removing 10 owner calls (1258 to 1248 in the closed build). `BC2CPP_DECLARED_UNION=0` restores the old output.
