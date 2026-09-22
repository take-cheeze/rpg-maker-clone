- `Game::State`, `RPG2k`, `RPG2k::Scene::Map::LRUBitmapCache`, `Game::Timer`
  and `LCF::Tree` join `BC2CPP_WIRED_EMBEDDINGS`, so their Fixnum/bool ivars
  move from the ordinary dynamic table into an embedded struct the same way
  the existing wired classes already do. `Game::Actor` was investigated and
  rejected: its own `#initialize` calls `#faceset_index`, which reads
  `@faceset_index` before `#initialize`'s own first embedded-ivar write has
  run, so the read reaches an unallocated struct
  (`Game__Actor_faceset_index_impl` dereferencing a NULL `DATA_PTR`) --
  reproduced and confirmed via gdb, not merely suspected.
