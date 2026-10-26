- **bc2cpp**: the numeric operators, the native-registration dispatch chains and `Float#/` test types with
  mruby's predicate macros (`mrb_integer_p`, `mrb_float_p`, ...) instead of `mrb_type(v) == MRB_TT_*`. GCC did
  not inline `mrb_type` in large generated bodies, so each tag test was an out-of-line call (844 in the optcarrot
  probe binary). Optcarrot, 180 frames: 3.79 s to 3.47 s wall. See `docs/bc2cpp-type-tests.md`.
