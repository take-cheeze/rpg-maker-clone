# C++ Fiber for compiled code

Status: the runtime (`tools/bc2cpp/runtime/bc2cpp_fiber.hxx`, `bc2cpp_fiber_methods.hxx`) and its host check
(`scripts/bc2cpp/cxx_fiber_check.rb`) exist, and the code generator uses them for one shape (below).

## Protocol

A body that can suspend is a step function over a heap frame:

```cpp
void step(mrb_state* M, Bc2cppFiberFrame* frame, mrb_value resume, Bc2cppStepOut* out);
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
  emit `Bc2cppFiberFrame` structs, `CALL` for every call to a suspendable method or block, and `YIELD` for
  `Fiber.yield`.
- Blocks that can reach `Fiber.yield` (the `Enumerator#next_values` body and its `each` block) have to compile
  as steps, so a `Fiber.new` body is a frame and not a bytecode proc.
- `Fiber.new`, `Fiber#resume`, `Fiber.yield` and `Enumerator#next` have to call this runtime instead of
  `mruby-fiber`.
- The nested Enumerable and Array methods (`collect`, `inject`, `sort_by`, ...) need their inner `each` as a
  step, so the block call becomes a `CALL`.

## Wiring plan

The verification target at each step is the set of resumable fixture checks that fail today with
`FiberError: can't cross C function boundary`: `resumable_args`, `resumable_optional`, `resumable_block`,
`resumable_rest`, `resumable_locals`, `resumable_receiver` and `resumable_variants` (all seven fail on a host
build after the driver removal; `native_fiber_check` is the closed-build counterpart).

A fixture's Fiber body is a literal block such as `Fiber.new { run(@base, @step) }`: a block that reads captured
state and calls a root method that reaches `Fiber.yield`. The chain from that block to the yield has three
kinds of link, and each has to be a step:

1. **Method steps move to the new ABI** (`codegen_resumable.rb`: `resumable_entry_function`, `emit_resumable_helpers`).
   The emitted step becomes `void step(M, Bc2cppFiberFrame*, resume, Bc2cppStepOut*)` over a frame struct that embeds
   `Bc2cppFiberFrame` and holds the registers. `RESUMABLE_YIELD` sets `out->kind = YIELD`; the inlined helper calls
   (`resumable_helper_call`) keep their flat inlining. `bc2cpp_resume_frame_p`, `Bc2cppResumable::Frame` and the
   `bc2cpp_resumable_*_from_c` helpers go; the entry called from outside a fiber uses `bc2cpp_run_to_completion`.
2. **A block call that cannot reach `Fiber.yield` is a direct call.** `RESUMABLE_BLOCK_CALL` exists today only so
   a VM driver can call the block from a VM frame. With no driver, a block that cannot suspend (the common case) is
   called straight from the step with `mrb_yield_argv`, with no suspension. Only a block that can reach
   `Fiber.yield` needs the next link.
3. **Blocks that can reach `Fiber.yield` are steps** (`resumable_block_site`, `block_call_site?`). Such a block
   compiles like a method step over its captured environment, and the call site returns `CALL` with its frame.
   This covers `Array#each { Fiber.yield }`, the `Enumerator#next_values` body and the nested Enumerable methods.
4. **The Fiber body is the root frame.** A `Fiber.new { ... }` literal compiles to `bc2cpp_fiber_new(M, root)`,
   where `root` is the block's step (a block step by link 3). `Fiber#resume`, `Fiber#alive?`, `Fiber.yield` and
   `Fiber.current` become a C++ `Fiber` class built on `bc2cpp_fiber_resume`; `Enumerator#next_values` is rewritten
   to use it.
5. **Remove `mruby-fiber` from the closed build** once the closed-build checks (`native_fiber_check`,
   `vm_bytecode_free_check`) pass without it.

Order: 1 and 2 first (behaviour-neutral outside a Fiber, so `resumable_*` checks that do not suspend keep
passing), then 3 and 4 together (the first point at which a fixture can pass), then 5.

## What is wired (first slice)

`Fiber.new { prologue; m(args) }` where the block's only call is a tail call on self to a suspendable method `m` of the
enclosing owner (`fiber_body_target_id`, `codegen_resumable.rb`):

- The site compiles to `bc2cpp_fiber_new_body`, a C++ Fiber whose root frame runs the compiled block with `m`'s id
  armed (`bc2cpp_prologue`). `m`'s entry sees its id armed, parks a `Bc2cppMethodFrame` (the adapter around the
  method's step) and returns at once; the fiber then calls that frame (`CALL`), and its `YIELD`s reach the resumer.
- The C++ Fiber answers as `Fiber`: `resume` and `alive?` serve a Bc2cppFiber and hand any other receiver to
  mruby-fiber's method, so the closed-world owner list (`Fiber`) needs no new entry. `Fiber` joins the core
  hierarchy (`sig/bc2cpp/core.rbs`), which also stops the analysis from treating `Fiber.new` as a block rebinder.
- The fiber keeps the values its frames hold alive through a hidden Array rebuilt after every step: mruby has no mark
  callback for a data object.

`resumable_args_check` and `resumable_locals_check` pass with it (interpreted and compiled runs print the same, two
fibers, `GC.start` between resumes). Still failing, each for a reason this slice does not cover:

- `resumable_optional_check`, `resumable_rest_check`: the body captures a local of the enclosing method (`base`), and
  a Fiber body outlives that frame, so the capture has to be by value.
- `resumable_block_check`: the body passes a block to the suspendable method (`each_mark { |x| Fiber.yield ... }`).
- `resumable_receiver_check`, `resumable_variants_check`: the body calls a core iterator on another receiver
  (`arr.each_index { Fiber.yield i }`), which needs block steps.
