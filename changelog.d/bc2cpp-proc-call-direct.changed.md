- **bc2cpp: core `x.call(*args)`, the failure reports and `Fiber.yield` from C no longer send by name**:
  `bc2cpp_proc_call_argv` looks `call` up once and runs the found method (private and protected `call` raise as the
  interpreter does, a missing one goes through `method_missing`), `$stderr` reports share `bc2cpp_stderr_report` (a direct
  IO write when `$stderr.puts` is the gem's own), and `Fiber.yield` from C is one helper. `mrb_funcall` in the closed
  build is 247 (baseline lowered); `scripts/bc2cpp/proc_call_helper_check.rb` compares interpreted and compiled runs.
