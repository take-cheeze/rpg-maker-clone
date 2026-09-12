- `tools/bc2cpp/bc2cpp.rb` now compiles real `super`/`super(...)` calls
  (`OP_SUPER`), a permanent gap since bc2cpp's own first version. Unlike
  RESCUE (docs/adr/0145), this needed no region-recognition machinery --
  `build_registry` now tracks each class's own declared superclass (a
  backward register-write walk off `OP_CLASS`'s own real shape, in the
  same spirit as the existing `.new`-receiver chain-walk), and
  `compile_insn`'s new `SUPER` case resolves a direct call through it,
  gated on a small, human-vetted `SUPER_TARGETS` allowlist (two
  whole-program facts -- no real caller ever passes a block, no
  interposed `include`/`prepend` -- that codegen can't re-verify locally
  at each call site). Unlocks 10 real methods in `mruby-rpg2k-compiled`
  (`RPG2k::Scene::Battle`/`DebugMenu`/`ItemMenu`/`Menu#initialize`,
  `RPG2k3::Scene::Battle`'s 6 update-family methods). Verified against a
  real runtime harness (a two-level bare-`super` chain dispatching with
  `self` intact throughout) as well as the usual real end-to-end regen +
  `register.cxx` compile. See docs/adr/0146.
