- **rpg2k**: `Game::Party` builds its member list with `<<` into a literal (initialize, `#reorder`), so bc2cpp proves
  `@actors` (and `Party#actors`) an Array.
