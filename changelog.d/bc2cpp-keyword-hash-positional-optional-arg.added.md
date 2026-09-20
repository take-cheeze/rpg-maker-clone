- **bc2cpp** now compiles a keyword-argument call site (`SEND ... nk=K`) whose
  callee declares no keyword parameters of its own but *does* take an
  `= default` optional positional (KEYWORD_HASH_POSITIONAL_OPTIONAL_ARG_SUPPORT).
  KEYWORD_HASH_POSITIONAL_SUPPORT's own gate was relaxed from
  `pure_mandatory_arity?` (every ENTER field zero) to a new
  `keyword_hash_positional_callee?`, requiring only ENTER's key/kdict fields to be
  zero — the real `MRB_ASPEC_KEY == 0 && MRB_ASPEC_KDICT == 0` that vm.c's OP_ENTER
  `if (!kd) { ci->n++; argc++; }` arm keys on — plus the call site's own
  `n + 1` inside the callee's accepted `[mand, mand + opt]` positional range. The
  packed keyword Hash then binds to the callee's next free positional slot exactly
  as real Ruby hands `foo(k: v)` to `def foo(a, b = 1)`. `*rest`/`&blk` callees
  stay excluded (their trailing-Hash slot isn't statically fixed). The optcarrot
  scoping probe goes 99.2%→99.5% (380→381; `batch_render_pixels`'s
  `expand_methods(fastpath, render_pixel: gen(...))`); `scripts/bc2cpp_coverage_report.rb`'s
  real-project output is byte-identical with and without the change.
