- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler can now emit a `def
  self.x`/`class << self ... end` singleton method as a real, compiled
  entry point, registered via `mrb_define_class_method` -- previously a
  documented "permanent structural limitation" (docs/adr/0139's own
  `RGSS::Bitmap`/`RGSS::Font` follow-ups). The real blocker turned out to
  be narrower than believed: a bare `def self.x` compiles to a single
  fused `SDEF` opcode whose own child-irep operand was being read and
  discarded, registering the method with no compiled body at all,
  purely for MONO/POLY devirtualization-soundness bookkeeping. Capturing
  that real, already-compiled irep (the same way every other definition
  opcode in this compiler already does) makes the method a real,
  individually compilable leaf, exactly like its `class << self`-defined
  sibling shape already was.

  `mruby-rgss-compiled`'s own `owners:` gains `RGSS::Bitmap.singleton` --
  this project's first `.singleton`-suffixed `owners:` entry -- covering
  both of `RGSS::Bitmap`'s own singleton methods: `self.extensions` (an
  `@extensions || EXTENSIONS` reader) and `self.failure_reason(f)`
  (previously assumed possibly uncompilable even with a real body; it
  compiles clean, and its own call to `extensions` correctly
  MONO-devirtualizes into a direct C++ call).

  Fixing the SDEF gap also surfaced and fixed a second, previously
  unreachable bug: a `.singleton`-owned method's own bare constant
  references (`EXTENSIONS`, `GAME_DIR`, ...) were building their
  owner-scope lookup chain from the literal pseudo-owner string, which
  would have looked up a constant named `"Bitmap.singleton"` (never real)
  and raised at runtime the first time such a method actually ran -- now
  correctly stripped back to the method's own real enclosing class before
  building that chain.

  Verified with a full before/after diff across all three compiled gems:
  the generated code for every already-shipped owner is byte-for-byte
  unchanged, and the whole-program MONO/POLY registry keeps the exact
  same entry count -- confirmed by `nm` on a real compiled object, not
  just by inspection.
