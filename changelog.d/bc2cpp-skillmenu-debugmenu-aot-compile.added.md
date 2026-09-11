- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 39 of
  `RPG2k::Scene::SkillMenu`'s own 46 real bytecode methods (the
  field/battle skill-use menu, including the teleport-skill map picker)
  and 33 of `RPG2k::Scene::DebugMenu`'s own 39 (the F9 debug menu itself:
  Switch/Variable editing plus the Map/Chipset/Animation tool pages).
  Both added to `mruby-rpg2k-compiled`. Neither needed any new opcode
  work. `RPG2k::Scene::DebugMenu#initialize` is the first shipped target
  blocked by a real `super` call rather than non-mandatory arguments, a
  Ruby block, or a `rescue` clause. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
