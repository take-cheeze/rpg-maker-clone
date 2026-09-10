- `tools/bc2cpp/bc2cpp.rb`'s compiled `_impl` functions are no longer
  `static`, and each run now also emits a standalone `<symbol>_decls.h`
  header of the same declarations -- the real, concrete precondition for
  a devirtualized call to ever cross a *gem* boundary (every compiled
  gem's generated file is its own translation unit; a `static` function
  can never link across one). New `OTHER_OWNERS`/`OTHER_DECLS_HEADER` env
  vars (mirroring `ONLY_OWNERS`) let one compiled gem trust another's own
  target classes; `mruby-lcf-compiled`/`mruby-rpg2k-compiled` now wire
  this mutually via a new shared `tools/bc2cpp/compiled_gems.rb`. No real
  cross-gem call exists in either shipped target's own output today
  (neither happens to call into the other's target classes) -- verified
  sound and zero-regression via the actual project build: both gems'
  `register.cxx` compile cleanly with the new mutual `#include`, and a
  full `RPGMAKER_BC2CPP=1` `libmruby.a` build archives cleanly with no
  duplicate symbols. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for why
  a parallel "unwrapped core" (raw C++ argument types instead of
  `mrb_value`) was explored and rejected -- this compiler's uniformly
  `mrb_value`-boxed internal representation means it wouldn't actually
  save any real work, only the linkage fix does.
