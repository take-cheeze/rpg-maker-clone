- **bc2cpp drops more by-name `mrb_funcall` text from the closed build.** The Proc
  `arity`/`parameters` stand-in calls `mrb_proc_arity` and the original
  `parameters` function directly, the inlined `loop` reads `StopIteration#result`
  and the no-method path sends through the shared `bc2cpp_funcall_argv`, the
  repeated `mrb_funcall_with_method` declarations are one, and generated notes say
  "by-name send" (`scripts/bc2cpp/step_closures_check.rb`,
  `scripts/bc2cpp/kernel_loop_check.rb`).
