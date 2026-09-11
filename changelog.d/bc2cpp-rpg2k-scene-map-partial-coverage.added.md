- Extended the opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler
  (`tools/bc2cpp/bc2cpp.rb`) to cover `RPG2k::Scene::Map`
  (`mruby-rpg2k/mrblib/scene/map.rb`) for the first time -- the main
  gameplay screen, already registry-visible for MONO/POLY
  devirtualization soundness, but never before an emission owner in any
  compiled gem. 222 of its own 408 real instance bytecode-defined
  methods compile clean and are registered in
  `mruby-rpg2k-compiled/src/register.cxx`; the other 186 stay
  interpreted for real, individually confirmed gaps (a real Ruby block,
  a `rescue` clause, a keyword/splat-argument call, or a non-mandatory
  `#initialize`-style argument -- never a silent drop). Its nested
  `RPG2k::Scene::Map::LRUBitmapCache` class and its own `def
  self.tone_channel` singleton method are unchanged and out of scope.
- No ivar of this class ends up embedded: `#initialize` itself has a
  keyword argument (`apply_access: true`), so `bc2cpp.rb`'s own
  `drop_unsafe_embeddings` gate refuses the whole class before its
  per-ivar safety check ever runs -- independently confirmed against
  the class's 5 raw ivar-embedding candidates by tracing every real
  read/write site by hand.
