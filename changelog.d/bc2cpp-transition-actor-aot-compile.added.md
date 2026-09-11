- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 32 of
  `Game::Transition`'s own 38 real bytecode methods (RPG2000's ~38 screen
  transition styles) and 75 of `Game::Actor`'s own 118 (real player
  stats/equipment/leveling/battle state) -- the biggest real target yet.
  Both added to `mruby-rpg2k-compiled`. `Game::Transition` needed no new
  opcode work and is the second real target (after `Game::Screen`) whose
  own `#initialize` compiles clean and gets real ivar embedding.
  `Game::Actor` needed three new opcodes in `tools/bc2cpp/bc2cpp.rb`:
  `GETIDX`/`SETIDX` (a computed-index Array/Hash read/write) and `GETGV`
  (a bare global-variable read) -- which also unlocked 348 more real
  method bodies across roughly 30 other classes project-wide, well beyond
  `Game::Actor` itself, including 2 more `Game::Screen` methods
  (`#load_h`, `#pan`) left blocked by the previous round. `Game::Screen`
  is now at 41 of its own 43 real methods. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
