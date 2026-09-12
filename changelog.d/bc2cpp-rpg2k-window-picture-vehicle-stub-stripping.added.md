- The wio, `RPGMAKER_BC2CPP=1` build now also strips the interpreted-
  bytecode body of every `mruby-rpg2k-compiled`-registered method on 5
  more previously-uncovered owners (docs/adr/0144's own
  `wio_strip_bc2cpp_stubs` mechanism, round 45 of the series): `RPG2k::Window`
  (32 methods, `main.rb`), `RPG2k` itself (15, `main.rb`), `Game::Picture`
  (25, `game.rb`), `Game::Vehicle` (4, `game.rb`), and
  `RPG2k::Scene::Map::LRUBitmapCache` (5, `scene/map.rb`) -- 81 methods
  total. A real measured `mrbc -g` reduction: `game.rb` 83,688 -> 79,464
  bytes, `main.rb` 28,028 -> 17,016 bytes, `scene/map.rb` 122,491 -> 121,733
  bytes (15,994 bytes combined).
- With these 5 additions, every `mruby-rpg2k-compiled`-registered owner
  that is not entirely confined to a file the wio build already excludes
  from `spec.rbfiles` (the battle/debug-tools/lsd-interop trims) is now
  covered by `mruby-rpg2k/mrbgem.rake`'s own `wio_strip_bc2cpp_stubs`
  `owners:` list (60 of 75 real owners; the other 15 are confirmed no-ops
  for wio today) -- the same complete-modulo-file-exclusions coverage
  state `mruby-rgss`/`mruby-lcf`'s own `owners:` lists already reached.
- One entry from an earlier survey of the remaining candidates,
  `Game::State.singleton`, turned out on re-verification to be a real
  no-op (both of its own registered methods live in the wio-excluded
  `game/lsd_io.rb`, not `game.rb` as that survey had assumed) and is
  correctly left out of this round's own additions.
