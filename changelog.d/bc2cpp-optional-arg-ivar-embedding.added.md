- **bc2cpp** drops a redundant, overly conservative arity check that
  blocked ivar-struct embedding for any class with an optional/rest/keyword
  `#initialize` argument, closing the exact gap `docs/adr/0139` flagged for
  `Game::Picture`/`RPG2k::Window` and every registration-completeness ADR
  since repeated. `compile_method`'s struct allocation is already
  unconditional and arity-independent, so `compiles_clean?` alone is the
  correct gate. 10 more real classes now embed (`RPG2k::Window`,
  `Game::Battle`, `Game::Enemy`, `Game::Party`, `Game::TextReveal`,
  `RPG2k::Scene::Map`/`MapViewer`/`ChipsetEditor`/`EquipMenu`/`SkillMenu` --
  77 ivars total, including the main map scene). Verified via a full
  before/after diff (zero regressions, zero new `#error`), all 22 static
  checks, and a real linked `RPGMAKER_BC2CPP=1` build that boots to the map.
  See ADR 0193.
