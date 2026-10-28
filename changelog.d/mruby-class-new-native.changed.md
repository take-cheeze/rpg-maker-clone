mruby fork: native `Class#new`, no VM entry

`Class#new` was a hand-written static irep (`allocate`, then
`initialize(*args, **kw, &blk)`), so every `new` the compiler did not inline ran
in the VM. The fork now has a cfunc in the Class ROM table that allocates and
sends `initialize` with `__send__` semantics (private methods callable,
keywords and block forwarded, the callee's argument count checked). `initialize`
runs under a C frame, so a `Fiber.yield` inside it raises `FiberError` instead
of suspending, as the yield analysis already assumed. The 3rd/mruby pin moves to
`claude/class-new-cfunc`; `EnumeratorModel` reads the names the cfunc sends from
`src/class.c`.
