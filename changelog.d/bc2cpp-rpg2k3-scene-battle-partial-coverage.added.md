- Extended the opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler
  (`tools/bc2cpp/bc2cpp.rb`) to cover `RPG2k::Scene::Battle`
  (`mruby-rpg2k/mrblib/scene/battle.rb`) for the first time -- the
  RPG2000 turn-based fight scene itself (the phase machine, the
  command/skill/item/target windows, the troop/party sprites, the
  per-action round animation, the battle-event pages, the result
  screen), the shared base class `RPG2k3::Scene::Battle` (already a
  compiled owner) extends for RPG2003's ATB gauge variant. Already
  registry-visible for MONO/POLY devirtualization soundness since the
  very first round, but never before an emission owner. 110 of its own
  174 real bytecode-defined methods compile clean and are registered in
  `mruby-rpg2k-compiled/src/register.cxx`; the other 64 stay on the
  interpreter for six distinct, individually confirmed gaps (a real
  `super` call in `#initialize`, 48 genuine Ruby-block users, one
  genuinely new opcode pair -- `BLKPUSH`/`BLKCALL`, for
  `#cached_bitmap`'s own implicit-block `yield` -- never seen by this
  compiler before, 7 real keyword-argument-heavy call sites, 2 real
  `rescue StandardError` clauses, and 5 methods with a non-mandatory
  argument -- never a silent drop). No ivar of this class ends up
  embedded: `#initialize` never compiles, and this was double-checked
  directly against the real diagnostic's own `== ivar embedding ==` and
  `== classes needing MRB_SET_INSTANCE_TT ==` sections, not just
  inferred, given a prior round's own live `Game::Transition`
  embedding-safety bug in this exact area. `RPG2k3::Scene::Battle`'s
  own already-shipped 7 registered methods are unaffected; a handful of
  its own dynamic-dispatch calls into base-class methods this round
  newly compiles now devirtualize into a direct C++ call instead. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for the
  full per-method breakdown and verification writeup.
