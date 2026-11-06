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

`resumable_args_check`, `resumable_locals_check`, `resumable_rest_check` and `resumable_optional_check` pass with it
(interpreted and compiled runs print the same, two fibers, `GC.start` between resumes).

A body may capture locals of the enclosing method (`Fiber.new { run(base) }`): a Fiber outlives that frame, so the
site copies the locals into a heap Array (the block reads them through pointers into it; the Array rides in the
block's env so the GC keeps it). That is sound only when nothing can change the local afterwards, so
`fiber_body_by_value?` accepts a mandatory parameter that no instruction in the enclosing method writes, in a body
with no SETUPVAR; any other capture keeps the old form. The prologue may use GETIV, GETUPVAR, MOVE, the literal loads
and STRING; its only call is the tail call.

A tail call may pass a literal block (`Fiber.new { each_mark { |x| Fiber.yield x * 10 } }`). The method's entry copies
that block to the heap when it parks its frame (the block may be a frame-local stack block), and the block's own
`Fiber.yield` is handled as a tail yield:

- A block whose last act is `Fiber.yield v` (`tail_yield_block?`) has nothing left to resume after the yield. When the
  adapter calls such a block from a block-call suspension, it arms the block's env (`bc2cpp_tail_yield`); the block's
  direct entry (`Bc2cppTailYieldScope`) sees the match, and the tail yield stores `v` and returns instead of calling
  `Fiber.yield`. The adapter yields `v`, and the next resume value is the block's result, which the method's step
  takes as its resume value. Anywhere else the same block yields the ordinary way.

`resumable_block_check` passes with it.

A tail call on an explicit receiver (`Fiber.new { arr.each_index { |i| Fiber.yield i } }`) is a Fiber body too. The
receiver's class is not proven, so the body arms "#each_index" (any owner's `each_index`) and its tail call stores
the receiver it is calling on (`bc2cpp_prologue_set_recv`); an entry takes the handoff only when its own name and its
`self` match, so a method that merely calls another `each_index` cannot. The prologue's tail call goes through the
entry (no inlined core arm), and a dual iterator's wrapper takes its variant when a Fiber body is armed
(`bc2cpp_prologue.expect`) as well as under an mruby Fiber. `resumable_receiver_check` passes.

## Block steps

A literal block whose `Fiber.yield` is not its last act (`{ |x| got = Fiber.yield x; got.to_i + 1 }`) is compiled a
second time as a resumable step (`block_step_candidate?`, `compile_block_step`): its irep is compiled as a synthetic
method of the enclosing owner, so its registers live in a frame and its `Fiber.yield` is a YIELD. The block's proc
carries a frame maker in its env (the slot before the entry; flag bit 2). At a block-call suspension the fiber's
adapter asks the maker for the block's frame and returns `CALL`: the block runs as a frame of the fiber, its yields
reach the resumer, and its result becomes the suspended method's resume value. Steps are compiled ahead of the owner
(`compile_block_steps`, including blocks nested in a Fiber body) so nothing is mid-flight.

Limits: no captured locals, no nested block, no `break`/`return`/`yield` to the method's block, and mandatory or
rest-only parameters; a block outside them keeps its tail yield or the call from C. `block_step_check` passes.

## Step-to-step calls

A suspendable method that calls another suspendable method on self with arguments (`a = ask(3)`) no longer needs
the callee inlined. The roots close over the suspendable methods they call (`CALL_STEP`, `codegen_block_fallback.rb`).
The caller's step makes the callee's frame at the call site (`resumable_call_site`): it arms the callee's id and
calls the callee's `_impl`, whose entry parks its frame (`bc2cpp_prologue`); the step stores that frame in the
suspension (`Bc2cppResumeFrame::callee`) and suspends, the adapter returns `CALL`, and the callee's result is the
caller's resume value. A callee's `Fiber.yield` reaches the resumer. The entry's own argument-count check is gone
(the registered wrapper checks, and a CALL site reaches `_impl` straight from compiled code, where the caller's
count is not the callee's). `call_step_check` passes.

Limits: calls on self to one definition in the same owner; no explicit receiver.

## Blocks inside steps

A step may build blocks. A block that cannot suspend runs as in any method: its callee is synchronous, so the
address-of-local captures stay valid. A call on self to a suspendable method that takes a block, with a literal block
whose body reaches `Fiber.yield`, is a CALL that carries the block (`resumable_block_call_glue`): the block's proc is
built on the heap with its step maker (nothing in it points into the step's frame, since a block step has no captured
locals), the callee's entry parks its frame with that block, and the callee's `yield` CALLs the block's step. The roots
close over such callees (`BLOCKS_IN_STEPS`, `codegen_block_fallback.rb`), and their names count as yielding names. The
plain body of a block that has a step is compiled outside the enclosing step, so a `Fiber.yield` in it is an ordinary
send that only runs when no fiber CALLs the step. `block_in_step_check` passes.

A block step may contain blocks of its own (the body of a Fiber body step, or of a block step, builds its blocks the same
way), and may read and write locals of the step that builds it (`BLOCK_STEP_UPVARS`). The building step's registers are
references into its heap frame whenever its body takes a register's address, so the site passes `&rN` pointers in the
block's env; the maker copies them into the block frame's slots (`F->slots[i]`) and the step reads them as the
`bc2cpp_upvar_*` pointers an ordinary block body gets (`GETUPVAR`/`SETUPVAR` are unchanged, writes go through
`bc2cpp_upvar_root`). This holds because the call is a CALL: the building step's frame stays on the fiber's stack until
the callee returns. A `Fiber.new` body never takes this form (it outlives the frame); it keeps the by-value capture.

Limits: the block takes level-0 captures only, no break/return/yield to the method's block, mandatory or rest-only
parameters; the callee has mandatory parameters, one definition in the same owner, and yields to its block; the site is
at the top level of the step, not in an inlined loop. Two callees with the same name are not CALL targets. Dynamic
dispatch (`Enumerator#each`, `send`) is not covered.

## Dynamic calls

A call in a step whose callee is not a known suspendable method of the same owner goes through `bc2cpp_dyn_call`
(`DYN_CALL`, `RESUMABLE_DYN_CALL` in the generated step): `send`/`__send__`/`public_send`, and a call with a literal or
forwarded (`&blk`) block on any receiver (`[1, 2].each { Fiber.yield }`, `val.upto(last, ex, &block)`). Each suspendable
method (and the resumable variant of a core iterator, under its fast body's registered function) emits a dispatcher
(`<impl>_dyn`) and registers it; mandatory, optional and rest parameters are supported. The call resolves the method on the
receiver and, when it is registered and the argument count fits, arms the method's id and runs its entry, which parks the
frame; the step CALLs that frame. Anything else runs as an ordinary call with the block and its value is the site's result
at once. A root that sends by name also makes the methods its symbol literals name roots. `block_in_step_check` covers it.

Keywords and splats: a `send`-family call, or a call with a forwarded block, may carry a splat, keywords and a block in any
shape (`@obj.__send__ @meth, *@args, **@kwd, &block`): `dyn_call_shape` finds the operands, the name is the first element of
a packed array for `send`, and the keyword Hash (or literal key/value pairs) goes to `bc2cpp_dyn_call`. A suspendable method
takes no keywords, so an empty Hash dispatches to the registered step and a non-empty one runs as an ordinary send that carries
them (`mrb_funcall_send`). A method with an explicit `&block` parameter is a CALL target. When some method a fiber reaches
sends by name, the program's other yielding methods that a symbol literal names become roots (`dynamic_send_targets`).

Limits: a block passed to a send whose name is not proven stays a possible rebinder (block_self_world), so it is not a step.

## Enumerator#next

`BC2CPP_ENUMERATOR_FIBER=1` (opt-in; off by default) lets mruby-enumerator's `next_values`, `each` and
`__enumerator_block_call` compile instead of staying bytecode (`CoreMethods.enumerator_fiber_step?`). `next_values` then
builds its Fiber from two block steps (the body and the `each do |*args| Fiber.yield args ... end` block), `Enumerator#each` is a
registered step, `__enumerator_block_call` forwards through a keyword-carrying dynamic call, and `obj.instance_eval { @args }` /
`{ @args = args }` compile as an ivar read/write (`INSTANCE_EVAL_IVAR`). `Enumerator#next` over `Array#each`, a user `each` reached
through `to_enum` with an argument, `each_with_index`, `Hash#each` and `Integer#times` runs on the C++ Fiber
(`enumerator_next_check`). Iterators that are not registered steps (for example `Enumerable#each_slice`) still reach
mruby-fiber's `Fiber.yield`.

## Inner blocks that yield

A block inside a step may call the block of the method that built it (`n.times { |i| out << yield(i) }`) or a proc held in a
variable (`block.call(*val)` in `Enumerable#collect`): the block is a step, its env carries the building method's block after
the upvars, the maker passes it as the step's block parameter, and the suspension records the proc it calls in the frame
(`__block__`) for the adapter. An inline loop (`each`, `times`, ...) whose block may suspend is not inlined in a step, so it
stays a block. Block steps are also built inside resumable variants. `resumable_variants_check` now builds every fiber body
in a compiled probe class; the iterators whose blocks return or break early (`all?`, `any?`, `detect`, `find_index`,
`none?`, scenarios with `break`) and those that go through `super` (`Range#max`, `#min`) or the native `Array#sort` are
listed in the check as known gaps, and a gap that starts passing fails the check.

## General Fiber bodies

A `Fiber.new` body that is not a single tail call (several calls to suspendable methods, a `Fiber.yield` of its own, a
result used after a call) is compiled as a block step, and the fiber's root frame is that step's frame
(`emit_fiber_body_step_site`, `bc2cpp_fiber_new_step`). Its calls to suspendable methods are CALLs. A body qualifies
under the block-step limits (no captured locals, no parameters), and it is a step whether or not it can suspend, since a
Fiber over a compiled proc needs a frame to run. It suspends through a `Fiber.yield` of its own, a call to a suspendable
method, or a block that yields. `fiber_body_step_check` passes. A body of the
prologue-and-tail-call shape keeps that form, which also captures parameters by value.

Still failing:

- `resumable_variants_check` known gaps (10 fiber scenarios): early return/break from a block inside a step, `super` in a
  step (`Range#max`/`#min`), the native `Array#sort` with a yielding block.
- Keyword arguments through a dynamic call, so `Enumerator#each`'s `@obj.__send__ @meth, *@args, **@kwd, &block` is not a CALL.
