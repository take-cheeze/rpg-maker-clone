- Fixed a regression that broke `psp-smoke` (and would have broken any other
  32-bit-`mrb_int` cross target loading `LCF`, `RGSSAD` or `Wolf`):
  `LCF::INT32_MASK`/`INT32_SIGN_BIT`/`INT32_WRAP`, `RGSSAD::START_KEY`/`MASK`/
  `DEFAULT_V3_SEED` and `Wolf::INT32_MASK`/`INT32_SIGN_BIT`/`INT32_WRAP`
  (all recently hoisted from per-call bare literals into module/class
  constants computed via `Integer#<<`/`#|`) are bare hex literals again.
  mrbc constant-folds a shift or OR whose operands are both literals at
  *compile* time, and the resulting bignum-pool entry does not survive
  being cross-compiled by this project's own 64-bit-`mrb_int` host `mrbc`
  and then loaded by a 32-bit-`mrb_int` target VM: `mrb_load_irep_file`
  on the 32-bit side fails the whole compiled gem with "irep load error"
  before any of its code runs — on the PSP target this happened while
  loading `mruby-lcf`, so `mruby-rgss`'s own gem init never ran and the
  next mruby call (`app/psp/main.cxx`'s `rgss_set_display`) crashed with
  "uninitialized constant RGSS" instead. A bare bignum literal's own pool
  entry does not have this problem, so the fix keeps the "computed once,
  at load time" win (a plain hex literal assigned to a module/class
  constant is still loaded via one `OP_LOADL` at load time, not re-parsed
  per call) while staying loadable on every target. Also fixed a second,
  pre-existing instance of the same bug in `LCF.pack_double`'s NaN
  fraction (`1 << 51`), unrelated to the recent hoisting but equally fatal
  to loading `mruby-lcf` on a 32-bit target regardless of whether that
  method is ever called.
