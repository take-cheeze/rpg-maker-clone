- The bc2cpp type check types integer arithmetic constants (`X = A - B`, `X = A / B + 1`, ...) as `Integer` when every
  definition of the name has a Fixnum interval, so `RPG2k::Scene::Map::COLS`, `SaveLoad::VISIBLE_SLOTS` and 12 other
  layout constants are no longer untyped. The proof is withheld when the program redefines an Integer operator or
  prepends a module into Integer. Covered by `scripts/bc2cpp/integer_arith_constant_check.rb`.
