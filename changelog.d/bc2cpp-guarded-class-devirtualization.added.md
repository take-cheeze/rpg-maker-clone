- `tools/bc2cpp/bc2cpp.rb` can now devirtualize `@ivar.method` (a known
  ivar) and an opaque-argument-typed receiver, not just a fresh same-body
  `SomeClass.new(...)`. Two new pieces: `ClassAnnotations` (a second,
  independent reader of the existing `# bc2cpp: (...)` comment syntax --
  `# bc2cpp: (Game::State)` claims "always exactly this real class",
  never reaching `IvarLayout`'s embedding lattice) and `ClassLayout`
  (the object-reference analogue of `IvarLayout`: a whole-program,
  fixed-point "this ivar always holds exactly this class" analysis).
  Every hit through this path -- including the original same-body `.new`
  case, extended to share it for free -- now emits a real runtime
  `mrb_obj_class` check before the direct call, falling back to
  `mrb_funcall` if it doesn't match: strictly *safer* than the existing
  name-only MONO devirtualization, which has no runtime check at all.
  Found and fixed two real bugs surfaced while building this (neither
  previously live): `trace_new_target`'s `GETCONST`/`GETMCNST` cases
  fired even without a preceding `.new`, misreading a bare Integer
  constant as a class name; and `GETCONST`'s own name extraction (a
  pre-existing bug in the already-shipped codegen) captured a trailing
  local-variable-name comment on a named-local destination register.
  Real whole-program payoff: 34 real `TYPED` devirtualizations (up from
  0), plus 21 real profiled class annotations applied to actual
  `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss` source (`profile_annotations.rb`
  extended to surface class-confirmed evidence it was previously
  discarding). Verified via real toy cases (built, linked, run) and both
  already-shipped compiled targets (byte-identical or cosmetic-only).
  See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
