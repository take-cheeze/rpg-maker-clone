# C++ Fiber for compiled code

Status: the runtime (`tools/bc2cpp/runtime/bc2cpp_fiber.hxx`) and its host check
(`scripts/bc2cpp/cxx_fiber_check.rb`) exist. The code generator does not use them yet.

## Protocol

A body that can suspend is a step function over a heap frame:

```cpp
void step(mrb_state* M, Bc2cppFrame* frame, mrb_value resume, Bc2cppStepOut* out);
```

A step runs until it reports one of three things in `out`:

- `DONE`: the body finished; `out->value` is its result.
- `YIELD`: the body suspends; `out->value` goes to whoever resumed the fiber.
- `CALL`: the body needs another suspendable body to run first; `out->callee` is a new frame, owned by the fiber
  from then on. Its result becomes the next `resume` value of the calling frame.

A `Bc2cppFiber` owns a stack of frames. `bc2cpp_fiber_resume` runs the top frame's step and follows `CALL`
(push) and `DONE` (pop and feed the parent) until a frame yields or the last frame finishes. No C++ frame
stays between a `YIELD` and the resumer, so no VM frame is needed to suspend and `Fiber.yield` is never called.
The `Enumerator#next` shape (an `each` whose block yields each element) is a frame that calls a block frame per
element; the check runs it under `mrb_full_gc`.

An exception in a step kills the fiber (its frames are freed) and propagates to the resumer, as an mruby Fiber
does. `bc2cpp_run_to_completion` runs a suspendable body from code outside a fiber; a `YIELD` there raises
`FiberError: can't yield from root fiber`.

GC: the fiber is an `RData`; its mark function calls each frame's `mark`, which marks the `mrb_value`s the frame
holds.

## Not done

- The code generator still emits step functions for the old frame (`Bc2cppResumeFrame`) with no `CALL`. It has to
  emit `Bc2cppFrame` structs, `CALL` for every call to a suspendable method or block, and `YIELD` for
  `Fiber.yield`.
- Blocks that can reach `Fiber.yield` (the `Enumerator#next_values` body and its `each` block) have to compile
  as steps, so a `Fiber.new` body is a frame and not a bytecode proc.
- `Fiber.new`, `Fiber#resume`, `Fiber.yield` and `Enumerator#next` have to call this runtime instead of
  `mruby-fiber`.
- The nested Enumerable and Array methods (`collect`, `inject`, `sort_by`, ...) need their inner `each` as a
  step, so the block call becomes a `CALL`.
