- Fix the Optcarrot bc2cpp probe's `compiled_run.rb`: a class bc2cpp proves
  has an embeddable ivar struct (`MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)`) now
  always gets every one of its own compiled methods installed too, not just
  a hand-picked Fiber-safety subset. Installing only some of a class's
  methods let `Optcarrot::APU#initialize` keep running interpreted (leaving
  its embedded struct's `DATA_PTR` null) while a devirtualized, Fiber-safe
  `#reset` call read that struct directly, segfaulting reproducibly.
  `Optcarrot::PPU` is excluded from compilation again pending a separate,
  unrelated fix: `PPU#run`'s `Fiber.new { ... }` compiles through bc2cpp's
  general block-fallback path into a cfunc-backed `Proc`, which mruby's own
  `Fiber.new` unconditionally rejects (`FiberError`) -- a real, always-
  reproducing bug distinct from the historical SIGSEGV concern that path was
  last cleared against. See `tools/optcarrot_probe/README.md`'s "Compiled
  runtime check" section.
