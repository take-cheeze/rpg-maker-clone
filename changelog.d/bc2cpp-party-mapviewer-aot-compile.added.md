- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 85 of
  `Game::Party`'s own 128 real bytecode methods (party-wide item/skill
  usability, equip/swap logic, skill damage formulas, battle placement)
  and 34 of `RPG2k::Scene::MapViewer`'s own 42 (the F9 debug-menu map
  overview/editor). Both added to `mruby-rpg2k-compiled`. Needed seven new
  opcodes in `tools/bc2cpp/bc2cpp.rb`: `NOP`, `ADDILV`/`SUBILV` (a `while`
  loop's own local-variable increment/decrement), `RANGE_INC`/`RANGE_EXC`
  (inclusive/exclusive Range literals), `RETURN_BLK` (a non-tail `return`),
  and `GETIDX0` (mrbc's own peephole for a literal `x[0]` index) -- which
  also unlocked `Game::Actor#set_exp` and 5 more real method bodies
  project-wide. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
