- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 7 of
  `RPG2k3::Scene::Battle`'s own 15 real bytecode methods (RPG2003's
  active-time-battle gauge behavior, a real subclass of the base UI
  battle scene), added to `mruby-rpg2k-compiled` alongside this round's
  other new target, `Game::Enemy`. Neither needed any new opcode work.

  This round's own dedicated bug-fix pass closed a seventh structural gap
  in the whole-program MONO/POLY devirtualization registry that a prior
  round's bug-fix pass had already found and confirmed real, but
  deliberately left unfixed to avoid scope creep: `mrbc`'s own compiler
  falls back to an unfused `TCLASS`/`SCLASS`+`METHOD`+`DEF` three-opcode
  sequence -- instead of the single fused opcode the registry already
  recognized -- whenever a class/module body already contains more than
  255 real method/block child ireps. Confirmed real with actual bytecode
  disassembly against `RPG2k::Scene::Map#toned?`/`def self.tone_channel`,
  both previously invisible to the registry entirely (not currently
  exploitable, since that class isn't yet a compiled owner, but real and
  general). Fixed by recognizing the real opcode triple (walking past the
  `EXT1`/`EXT2`/`EXT3` pseudo-instructions mrbc's own disassembler
  interposes for a wide operand, and verifying the exact register
  alignment the compiler always emits) and registering the resulting
  method as a real, walkable entry -- confirmed the real diagnostic's
  registry dump now shows both names correctly. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
