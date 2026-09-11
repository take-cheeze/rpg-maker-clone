- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 12 of
  `Game::Map`'s own 13 real bytecode methods (one loaded map's own
  tile-layer data: dimensions/chipset id, the lower/upper tile-id layer
  arrays, and Tile Substitution's own per-layer rewrite table), including
  its own `#initialize`. Added to `mruby-rpg2k-compiled`. No new opcode
  work was needed -- the one remaining gap, `#substitute_tile`, ends in
  two genuine Ruby blocks, an already-established out-of-scope shape.
  `Game::Map` is the fourth target (after `Game::Screen`/
  `Game::Transition`/`Game::State`) whose own ivars get real `RData`
  embedding: `@id`/`@revision` are both provably Fixnum, verified safe
  against the earlier `Game::Actor` embedding bug by confirming this
  class's one real construction site always goes through the compiled
  `#initialize`. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
