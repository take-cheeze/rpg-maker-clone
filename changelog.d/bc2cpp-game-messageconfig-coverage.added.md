- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `Game::MessageConfig` (the Message Options settings object: window
  transparency, text position, face-graphic selection) in
  `mruby-rpg2k-compiled` -- 4 of its own 5 real bytecode-defined methods
  (`#initialize`, `#face?`, `#clear_face`, `#to_h`). No new opcode work
  was needed. `#load_h` stays on the interpreter: both its early-exit
  `return self unless h` and its own trailing bare `self` disassemble to
  `RETSELF`, an mrbc opcode this compiler has no `compile_insn` case for
  yet (safe either way -- an unsupported opcode just leaves the whole
  method on the interpreter).

  A deliberate stress-test of the eighth severe bug's own fix
  (`natively_exposed?`, guarding against a plain `attr_reader`/`attr_writer`/
  `attr_accessor` colliding with an ivar embedded into a real `RData`
  struct): every one of this class's own 8 ivars is covered by a plain
  `attr_accessor`. Checked directly against the real diagnostic, not
  assumed: `@face_index` (provably Fixnum, via a self-call into
  `#clear_face`) genuinely reaches the ivar-embedding proposal pass
  (`EMBED Game::MessageConfig#@face_index (fixnum)`) but is then
  correctly vetoed because of `attr_accessor :face_index` -- confirmed
  this class does not appear in bc2cpp's own "classes needing
  MRB_SET_INSTANCE_TT" diagnostic, and the regenerated `#initialize`/
  `#clear_face` bodies write it via plain `mrb_iv_set`, never
  `mrb_data_init`. `@position` (assigned from a `GETCONST`-fed constant,
  not a literal) is never even proposed as an embedding candidate in the
  first place -- a distinct, independent reason, the same
  two-reasons-at-once shape this project's `LCF::Tree` follow-up already
  documented for a sibling gem.
