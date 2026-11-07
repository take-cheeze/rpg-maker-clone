- **bc2cpp** C++ Fiber: `Fiber#raise(...)` on a fiber of compiled code raises the exception at the `Fiber.yield` the fiber is
  suspended at, so the rescue and ensure bodies of its steps run (an ensure body may yield again, a rescue lets the fiber run
  on). The current and root fibers raise in place, a fiber waiting on one it resumed forwards to the running fiber, an unborn
  fiber is a `FiberError`, a dead one the `FiberError` of a resume. mruby-fiber has no `Fiber#raise` (the call reaches the private
  `Kernel#raise`), so the owner-call guard accepts the runtime's definer (`bc2cpp_fiber_definer_p`; the closed world's `raise` stays Kernel's alone);
  a compiled `fiber.raise` works with and without mruby-fiber. `step_exceptions_check` and `native_fiber_check` hold it to CRuby's output.
