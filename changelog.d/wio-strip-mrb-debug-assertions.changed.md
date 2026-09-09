- **Wio Terminal: stripped `MRB_DEBUG` (mruby core's C-level `assert()`
  calls) from the build.** `enable_debug` sets three separate things;
  ADR 115 already handled mrbc's own `-g` (Ruby bytecode debug tables) and
  `-g3` (native DWARF) was always harmless, but `MRB_DEBUG` -- which turns
  ~100 `mrb_assert()` call sites across mruby's own VM/GC/class code into
  real `assert()`s, each with its own branch and string literal -- was
  still on. Real relink: 17,692 bytes of flash recovered, no RAM cost. See
  ADR 117.
