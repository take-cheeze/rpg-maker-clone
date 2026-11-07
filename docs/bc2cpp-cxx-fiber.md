# C++ Fiber for compiled code

bc2cpp compiles `Fiber.new { ... }` bodies, and the methods and blocks they call that can suspend, into step functions
over heap frames. A C++ Fiber (`tools/bc2cpp/runtime/bc2cpp_fiber.hxx`, `bc2cpp_fiber_methods.hxx`) runs them, so
compiled code never calls mruby-fiber. `Enumerator#next` runs on it too.

## What is supported

- `Fiber.new`, `#resume`, `#transfer`, `#alive?`, `Fiber.yield`, `Fiber.current` and `Fiber#raise`, with mruby-fiber's
  argument passing and `FiberError` messages. A fiber whose body raised is dead and the exception reaches the resumer.
- Suspending anywhere in a compiled body: through calls to compiled methods, `each` and other iterators with a compiled
  variant, blocks, keyword/optional/rest parameters, closures that outlive their frame, `rescue`/`ensure`/`retry`,
  `return`/`break`/`next`, `catch`/`throw`, `super`, and `Array#sort` with a yielding block.
- `Enumerator#next`/`peek`/`rewind` and the enumerator gems built on them (`mruby-set`, `mruby-enum-chain`,
  `mruby-enum-lazy`).
- A Fiber made by an interpreted (bytecode) `Fiber.new` is still an mruby-fiber Fiber and keeps working.

## Switches

- `BC2CPP_ENUMERATOR_FIBER=0` keeps mruby-enumerator's bytecode on mruby-fiber (default: on, `Enumerator#next` runs on the
  C++ Fiber).
- `BC2CPP_MRUBY_NOFIBER` / `BC2CPP_NOFIBER_BUILD_DIR` point `native_fiber_check` at an mruby built without mruby-fiber.

## Limits and known gaps

- `Fiber.yield` from a block run by a C iterator raises `FiberError` "can't cross C function boundary", as mruby-fiber
  does. Iterators that still differ from the interpreter: `Kernel#tap`/`then`/`yield_self`, `Proc#curry`,
  `lambda { Fiber.yield }.call`, `Enumerator.new`/`produce`/`Yielder` generators, and `Enumerable#chunk`/`lazy`
  (these raise that error when compiled).
- `Fiber.new(&blk)` and a Fiber made through `send` have no compiled path; only a literal-block `Fiber.new` becomes a
  C++ Fiber.
- Upvar roots of blocks that do not use cells (non-cell roots) are not released.
- `Fiber#raise` on a real mruby-fiber Fiber is a NoMethodError (mruby-fiber has none); it works on C++ Fibers.
- `mruby-rpgxp` (`script_host.rb`) and `mruby-wolf` (`interpreter.rb`) still need the real mruby-fiber, so the desktop
  and web builds keep it.
- `fiber_limits_check` pins each gap above (and break through several ensure regions, keyword calls that suspend) with a
  scenario that must still differ from the interpreted run; one that starts matching fails the check.

## Removing mruby-fiber

The closed build links a source-less `mruby-fiber` placeholder gem (`NOFIBER_PLACEHOLDER_GEM`), so its libmruby has no
`mrb_fiber_*` symbol (`vm_bytecode_free_check` asserts it) and satisfies the gems that declare
`add_dependency 'mruby-fiber'`. The runtime defines `Fiber`, `FiberError` and `Fiber.yield` itself
(`bc2cpp_fiber_define`). `native_fiber_check` runs compiled Fiber programs on that mruby and compares them with the
interpreted run, scenario by scenario (`KNOWN_GAPS` lists the differences; a gap that starts passing fails the check).

## Architecture

A suspendable body is a step `void step(mrb_state*, Bc2cppFiberFrame*, mrb_value resume, Bc2cppStepOut*)` that reports
`DONE` (result), `YIELD` (value for the resumer) or `CALL` (a callee frame to run first). A `Bc2cppFiber` owns a stack
of such frames; `bc2cpp_fiber_resume` follows `CALL`/`DONE` until a frame yields or the last one finishes, so no C frame
stays between a `YIELD` and the resumer. The GC marks the frames through the fiber's `RData`.

### Handlers, exceptions and unwinding in steps (STEP_HANDLERS)

Handler regions are states of the step; an exception is matched to the covering handler by `F->pc`, and
`bc2cpp_fiber_unwind` pops frames until one with handlers takes it. Checked by `step_exceptions_check`.

### Keywords, optionals and rest in steps (STEP_KEYWORDS)

A method with keyword, optional, rest or block parameters (any mix; `resumable_shape_problem` names the refused shapes)
is a step. Checked by `step_keywords_check`.

## Checks

`cxx_fiber_check` (runtime), `fiber_api_step_check`, `fiber_transfer_check`, `fiber_body_step_check`,
`step_exceptions_check`, `step_keywords_check`, `native_fiber_check`, `fiber_limits_check` and the `resumable_*_check`
family, all under `scripts/bc2cpp/`.
