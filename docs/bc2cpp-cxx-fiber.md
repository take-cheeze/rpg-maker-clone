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

On by default (`BC2CPP_ENUMERATOR_FIBER=0` keeps mruby-enumerator's bytecode and mruby-fiber): the methods of
mruby-enumerator's `enumerator.rb` compile instead of staying bytecode (`CoreMethods.enumerator_fiber_step?`; methods that
build a lambda stay bytecode). `next_values` then
builds its Fiber from two block steps (the body and the `each do |*args| Fiber.yield args ... end` block), `Enumerator#each` is a
registered step, `__enumerator_block_call` forwards through a keyword-carrying dynamic call, and `obj.instance_eval { @args }` /
`{ @args = args }` compile as an ivar read/write (`INSTANCE_EVAL_IVAR`). `Enumerator#next`, `peek`, `rewind` and `size` over
`Array#each`, a user `each` reached through `to_enum` with an argument, `each_with_index`, `Hash#each`, `Integer#times`, and an
Enumerable's own `each` (`to_enum`, `map`, `select`, `each_with_index`, `each_slice`, `each_cons`, `each_with_object`,
`with_index`, two independent enumerators) run on the C++ Fiber (`enumerator_next_check`). `each_slice`, `each_cons`,
`group_by`, `partition`, `min_by`, `max_by`, `take_while` and `drop_while` joined the dual list for this. An iterator that is
not a registered step still reaches mruby-fiber's `Fiber.yield`, which raises inside a C++ Fiber, so external enumeration over it
fails (the default is a trade: a closed build without mruby-fiber needs this; `BC2CPP_ENUMERATOR_FIBER=0` restores the old
behaviour for a program that walks such iterators).

Known gap (kept in `enumerator_next_check`, which fails when it starts passing): `Enumerator::Lazy#next`
(`src.lazy.map { }.select { }.to_enum` then `next`). mruby-enum-lazy is not among the core gems bc2cpp compiles
(`BC2CPP_CORE_MRBLIB_GEMS`), and its generator block wraps the iteration in `begin ... rescue StopIteration`, which a step cannot
contain yet. `Lazy#first(n)` works (it does not use a Fiber).

## Inner blocks that yield

A block inside a step may call the block of the method that built it (`n.times { |i| out << yield(i) }`) or a proc held in a
variable (`block.call(*val)` in `Enumerable#collect`): the block is a step, its env carries the building method's block after
the upvars, the maker passes it as the step's block parameter, and the suspension records the proc it calls in the frame
(`__block__`) for the adapter. An inline loop (`each`, `times`, ...) whose block may suspend is not inlined in a step, so it
stays a block. Block steps are also built inside resumable variants. `resumable_variants_check` builds every fiber body in a
compiled probe class; the one scenario that still fails (`Enumerable#sort`, which ends in the native `Array#sort`) is
listed in the check as a known gap, and a gap that starts passing fails the check.

## Return, break and super in steps

A block step may `return` from its method or `break` out of the call that took it (`BLOCK_STEP_UNWIND`). The step that
builds the block puts two frame values in the block's env, just before the maker: the frame a `break` ends (the building
step's own frame) and the frame a `return` ends (the building step's frame, or the target the building block step itself
carries). A block that returns or breaks has no thunk (direct-entry) proc, so its plain body keeps reading its tokens from
a cfunc frame; the step trailer on its env ends with a magic-tagged flag word (`BLOCK_STEP_MAGIC`) that the adapter
checks, so an env that merely ends in a pointer is not taken for one. When the block's step reaches `BREAK` or
`RETURN_BLK` it records the target in `Bc2cppResumeFrame::unwind_key` and returns its frame as a suspension; the adapter
reports `BC2CPP_STEP_UNWIND`. The fiber drops the frames above the target (found by `Bc2cppFiberFrame::identity`, the heap
frame of a method frame) and either resumes it with the value (break: the value is the call's result) or finishes it with
the value (return). A block that runs from C instead (the callee is not a registered suspendable method) breaks and
returns by exception: the dynamic call site owns a break frame and, in a method step, a return frame, and catches both.
A `return` out of a block that cannot suspend takes the same site, so a step can contain such a block. Limits: a plain
`return` from a block built by another block step has no return frame on the C stack, so it raises `LocalJumpError`
when the callee runs it from C.

`super` in a step is a dynamic call that starts above the method's own class (`bc2cpp_dyn_super`): a registered suspendable
target parks and is CALLed (`Range#max` into `Enumerable#max`), any other target is called as `bc2cpp_super_call` calls it.
An ordinary body takes a plain fixed-argument `super` with its block register through `bc2cpp_super_call` as well
(`SUPER_BLOCK_REGISTER`).

## Closures that outlive a step

A block that may be kept (the callee is not proven to leave it: `proc`, `Hash.new`, a stored block, a `Fiber.new` body that is
not the prologue-and-tail-call shape) captures the registers of the function that makes it through heap cells
(`STEP_CLOSURES`: `boxed` regions, `codegen_block_fallback.rb`). The function keeps those registers in one cells Array
(`bc2cpp_cells_ary`); each captured register is a C++ reference to its cell, so the body's code is unchanged and the pointers the
block's env already carries lead into the Array. The Array rides in the block's env, after the break/return tokens (the
slots before it and the readers that index from the end keep their places), and the block step's maker also hangs it on the
step's frame (`__cells__`), so neither the fiber's frame nor the C stack is needed to keep a variable alive. A step keeps the Array in one
more frame slot, made on the first run from the values the entry put in the captured registers' slots. A guard
(`Bc2cppCellsGuard`) re-grays the Array whenever the function exits, as nothing barriers the stores through raw pointers.
The cheap pointer form stays where the block provably does not outlive the call, and an inline loop whose block builds a boxed
region is not inlined (its registers would share the host's numbering).

This lifts the Fiber-body capture limits: written locals, optional and rest parameters and outer upvars. Limits: only the
registers of the function that makes the block (level 0) are boxed, so an escaping block nested in a block cannot capture the
grandparent's locals; a `$__bc2cpp_upvar_roots` entry per written slot address is not released when its cells go.

A compiled block's `Proc#arity` and `Proc#parameters` are answered from its registered `ENTER` word and local names
(`PROC_SPEC`, `bc2cpp_proc_spec_register`): a stand-in irep proc holds them and mruby's own methods answer. A block with
optional, rest-with-keywords or keyword parameters is not compiled (its method stays interpreted). `step_closures_check`
covers escaping closures in Fiber bodies, steps and ordinary methods, with the fiber bodies compiled, and passes under a GC-stress
mruby.

## General Fiber bodies

A `Fiber.new` body that is not a single tail call (several calls to suspendable methods, a `Fiber.yield` of its own, a
result used after a call) is compiled as a block step, and the fiber's root frame is that step's frame
(`emit_fiber_body_step_site`, `bc2cpp_fiber_new_step`). Its calls to suspendable methods are CALLs. A body qualifies
under the block-step limits (no captured locals, no parameters), and it is a step whether or not it can suspend, since a
Fiber over a compiled proc needs a frame to run. It suspends through a `Fiber.yield` of its own, a call to a suspendable
method, or a block that yields. `fiber_body_step_check` passes. A body of the
prologue-and-tail-call shape keeps that form, which also captures parameters by value.

## Fiber API

What a compiled body can use on the C++ Fiber (`fiber_api_step_check`, and the hand-written steps in `cxx_fiber_check`):

- `Fiber#resume(a, b)` hands the fiber `[a, b]` (one argument is itself, none is nil). `Fiber.yield a, b` hands the resumer
  `[a, b]`; a step packs them (`RESUMABLE_YIELD`, `bc2cpp_block_args_from`).
- Block parameters bind from the first resume's arguments: a `Fiber.new { |a, b| ... }` body is a step whose root frame
  (`Bc2cppBodyStart`) makes the body's frame on the first resume, with the arguments `bc2cpp_fiber_m_resume` stored
  (`bc2cpp_first_args`), and calls it. A body with parameters never takes the prologue-and-tail-call form.
- `Fiber.current` is the C++ Fiber being resumed (`bc2cpp_current_fiber`, restored when a resume ends, also by an
  exception) and, outside any C++ Fiber, mruby-fiber's root fiber, or the runtime's own root fiber without mruby-fiber
  (see "The root fiber object").
- A fiber whose step raised is dead (`alive?` is false) and the exception reaches the resumer.

### Transfer, nesting and the FiberError cases (`fiber_transfer_check`)

The fiber bodies of the check are compiled (a probe class per scenario; state a body reads lives in instance variables,
since a Fiber body does not capture the locals of the method building it yet).

- `Fiber#resume` / `Fiber#transfer` of a C++ Fiber run it nested on the C stack (`bc2cpp_fiber_resume(.., transfer)`) with
  mruby-fiber's rules and messages: `attempt to resume the current fiber`, `double resume` (a fiber on the resume chain),
  `resuming dead fiber`, `resuming transferred fiber` (a fiber suspended by a transfer away, or waiting on a fiber it
  transferred to), `attempt to transfer to a resuming fiber`. A transfer to the current fiber returns its value; a transfer
  to a yielded fiber continues it.
- A `transfer` send in a step is a runtime-checked yield (`transfer_site?`, `bc2cpp_transfer_is_yield`): when the receiver is
  the root or an mruby fiber that resumed the C++ Fiber, or the C++ Fiber whose resume/transfer runs it
  (`Bc2cppFiber::caller`), the step suspends with the value (`transfer` of x back to the resumer is `Fiber.yield x`), and the
  fiber is then marked as suspended by a transfer. Any other receiver takes the ordinary send, which for a C++ Fiber runs
  it nested. A fiber entered by a transfer cannot `Fiber.yield` (`attempt to yield on a not resumed fiber`).
- A fiber resumed from another fiber's step (nested resume), block parameters bound from `resume(3, 4)` ([3, 4]), and a
  transfer between two C++ Fibers (`FtChain`) match mruby-fiber.
- The fibers on the resume chain are rooted in a global Array (`bc2cpp_running_fibers`): `bc2cpp_current_fiber` and
  `Bc2cppFiber::caller` are raw values the GC does not see, and the arena that protected a running fiber belongs to the C
  function that started it. Under a GC that runs on every allocation (`MRB_GC_STRESS`) a fiber entered from C was freed while
  `Fiber.current` still returned it.
- Limit: a transfer ring of three or more fibers (A to B to C, then C back to A rather than to its caller B) is not
  modelled: the nested runs make it a call chain, so only a transfer to the fiber that ran this one is a yield.

Not done: `Fiber.yield` with a splat or keywords, and `Fiber.yield` from code the compiler did not compile.

## Array#sort with a yielding block

`Array#sort!` is C in mruby, so a `Fiber.yield` in its comparison block cannot cross it. A frame of the fiber
(`bc2cpp_fiber_sort.hxx`, `Bc2cppSortFrame`) runs array.c's insertion sort (up to 16 elements) and heap sort step by step;
each comparison is a block call (`bc2cpp_block_call`, the adapter's call factored out: a block step is CALLed, a tail-yield
block is a YIELD, any other runs here) that may suspend. It is registered for dynamic calls under `Array#sort!`'s C function
(`bc2cpp_dyn_builtins`) and declines (undef) when there is no block or fewer than two elements. `Array#sort` joins the
resumable variants, so `[..].sort { Fiber.yield }`, `Enumerable#sort` and `sort!` suspend. `resumable_variants_check` holds
these scenarios to a transcription of array.c's algorithm (the interpreted run cannot give their output).

## Entered from C

A resumable method entered as a frame of a C++ Fiber hands its CALLs to the fiber. Entered from C (an interpreted Fiber, the
VM, a native iterator: core iterators take their variant whenever `M->c` is not the root context) it had no fiber to hand
them to, and `bc2cpp_resumable_resume_from_c` took a CALL suspension for a `Fiber.yield nil`, so
`Fiber.new { [3, 1, 2].sort { |a, b| a <=> b } }.resume` in interpreted code raised FiberError, as did `collect`, `inject`
and `flat_map`. The frame a step CALLs now runs to its end there (`bc2cpp_run_callee_from_c`); a `Fiber.yield` in it goes to
`Fiber.yield` and raises the FiberError of a yield across a C frame. `call_from_c_check` covers it. A yield through compiled
iterators from an interpreted Fiber is a FiberError: it needs a compiled Fiber body.

## Handlers, exceptions and unwinding in steps (STEP_HANDLERS)

A step may have `rescue` and `ensure` handlers (`resumable_handler_problem` still refuses a `return`, `break` or leaving
`JMPUW` inside an ensure range, and `retry` is not handled).

- **Handler regions are states.** The step body is a lambda run under `mrb_protect_error`; every instruction stores
  `F->pc`. On an exception the loop finds the last catch handler (mruby's rule: last to first, `begin <= pc < end`) covering
  `F->pc`, sets `M->exc`, and re-enters the body at state `RESUMABLE_HANDLER_STATE + k`, which jumps to the handler target
  (`EXCEPT`/`RESCUE`/`RAISEIF` compile as in the VM). No covering handler: the step's `has_handlers` is cleared and the
  exception leaves the step.
- **Across frames.** An exception that leaves a step in `bc2cpp_fiber_resume` is caught by `bc2cpp_fiber_unwind`, which pops
  frames until one with `has_handlers` takes it (`unwind_into` sets `raise_pending`; the step re-raises at its checkpoint
  `F->pc`, so a handler in a parent step sees the exception after CALL frames above it died). With none left the fiber is
  finished and the exception leaves `Fiber#resume` (`alive?` is false).
- **Unwinds.** A `break`/`return`/`throw` UNWIND whose path crosses frames with handlers is converted to a `Bc2cppUnwind`
  exception, so ensure bodies run on the way; `RESCUE` never matches it.
- **catch/throw.** `bc2cpp_fiber_catch.hxx` replaces `Kernel#catch` (a bytecode method) and `Kernel#throw` (searches the VM
  ci stack) with native frames: `Bc2cppCatchFrame` calls the block, and `throw` UNWINDs to the frame with the tag.
  `catch` takes this path only when its block has a step; otherwise mruby's catch runs. `throw` finds only catch frames of
  the current fiber.

`step_exceptions_check` compares interpreted and compiled runs of a compiled probe class (nested ensure, exception through
CALL frames and out of `Fiber#resume`, local rescue, wrong rescue class, catch/throw, `break` through an ensure).

### The root fiber object

Without mruby-fiber nothing answers `Fiber.current` at the root. `bc2cpp_root_fiber` makes one `Fiber` object for the
main context (a `Bc2cppFiber` with `root` set and no frames, kept in the rooted global `$__bc2cpp_root_fiber`), and
`Fiber.current` returns it whenever no C++ Fiber is running, so `Fiber.current.equal?(Fiber.current)` holds. With
mruby-fiber the original `Fiber.current` still supplies the root, so the same compiled code runs on both.

- `alive?` is true and `inspect` is the default `#<Fiber:0x...>`.
- A compiled `main.transfer(x)` inside a fiber whose resumer is the root is a yield (`bc2cpp_transfer_is_yield` accepts the
  root object when `Bc2cppFiber::caller` is nil); the fiber is then suspended by a transfer and `f.transfer(y)` continues it.
- The cases that reach `bc2cpp_fiber_resume` with the root as receiver use mruby-fiber's messages: at the root, `resume`
  raises `attempt to resume the current fiber` and `transfer` returns its argument; inside a C++ Fiber, `resume` raises
  `double resume` and a `transfer` that is not a yield (the fiber was resumed by another fiber) raises
  `attempt to transfer to a resuming fiber`.

`native_fiber_check` covers it ('root fiber at the root', 'root fiber inside a fiber', 'root fiber transfer chain',
'root fiber errors', and the former 'fiber transfer' gap) against mruby-fiber's output.

## Keywords, optionals and rest in steps (STEP_KEYWORDS)

A method with keyword parameters is a step, alone or next to optional, rest and block parameters (`def each(start = 1,
*rest, stop: 3, &block)`). `resumable_shape_problem` refuses only a post parameter, a keyword rest next to named keywords
and the shapes `compile_method` itself cannot bind.

- **The ordinary compile binds more shapes first.** `compile_method` takes keywords next to a rest and/or block
  (`keyword_arg_table(rest_block: true)`, `optional_rest_arg_table` with `kw`, `optional_block_arg_table` with `kw`). The
  registered wrapper (`keyword_rest_block_entry`) binds everything in one call, `mrb_get_args("|o*:&")`: `*` ends the
  positional scan and `:` reads the keyword Hash. The impl takes the arguments, the rest Array, the block, the count of
  optionals given, then each keyword value (and a given flag for an optional one). With keywords the incoming block sits one
  register after the arguments (the keyword Hash slot is between). `bc2cpp_check_argc_kw` words an arity error as OP_ENTER does,
  counting a lone keyword Hash as the one argument given.
- **The step keeps the keywords in the frame.** The entry stores each keyword (and its given flag) in cells after the block
  and cells slots (`ResumableCtx#kw_base`); the step reads them into the locals `KEY_P`/`KARG` use, so the body is the plain one.
- **Dispatch.** A step with keywords registers `bc2cpp_dyn_register_kw`; its `_dyn` gets the call's keyword Hash and binds
  with `bc2cpp_dyn_bind_keywords` (the Hash is not changed). A call that does not fit (a missing required keyword, an unknown
  one) is declined, so the ordinary send runs the wrapper and raises the interpreter's ArgumentError. `bc2cpp_dyn_call` looks
  the method up for a call with keywords too: a step without a keyword dispatcher still takes the ordinary send that carries
  them. `_dyn` of a rest-with-optionals step is registered now (the given count is clamped to the optionals).
- **Call sites.** A call on self to a suspendable method whose callee is not mandatory-only, or whose call has keywords or a
  splat, is a dynamic call site (`resumable_call_site`) rather than a direct entry call; a `send`/`public_send`/`__send__`
  with keywords on self (an SSEND) is one too.
- **Nested block steps.** A block step nested in a Fiber body may read a local of the body's builder (a level-1 upvar): the
  body holds that pointer, and the inner maker forwards it (`block_step_upvars_ok?`). This is what a `begin ... ensure` block
  inside `Fiber.new` that records into the method's local needed.
- Not done: a call that carries keywords *and* a literal block is not compiled at all (the block region recognizer refuses
  `n=..|nk=..`, `mrb_funcall_with_block` cannot carry keywords), whatever the callee is.

`step_keywords_check` compares interpreted and compiled runs of a compiled probe class: required and optional keywords,
optionals, rest and block with keywords, keyword splat, `send`/`public_send`, and the ArgumentErrors.

## Without mruby-fiber

`native_fiber_check` runs compiled Fiber programs on an mruby that has no mruby-fiber, with the C++ Fiber as the whole
Fiber. The scenario program is a compiled probe class (every `Fiber.new` body in it is compiled); a few lines of
interpreted Ruby only call `resume` and `alive?` on the C++ Fibers. The no-fiber mruby is the full-core build minus
`mruby-fiber`, which a placeholder gem named `mruby-fiber` (no sources) stands in for, so mruby-enumerator and the gems on it
(`mruby-set`, `mruby-enum-chain`, `mruby-enum-lazy`, the 3rd-party `mruby-stringio`) build and run on the C++ Fiber
(`Bc2cppFixtureRuntime::NOFIBER_CORE_CONFIG`, `nofiber_or_build`, `BC2CPP_MRUBY_NOFIBER`/`BC2CPP_NOFIBER_BUILD_DIR`; an older
`BC2CPP_NOFIBER_BUILD_DIR` built before the placeholder has to be rebuilt). The program's output on it equals the interpreted run on the full-core
mruby, scenario by scenario, except `KNOWN_GAPS` (a gap that starts passing fails the check). The Array#sort lines compare
with the transcription of array.c's sort that `resumable_variants_check` uses, since the interpreter cannot yield there.

The runtime provides what mruby-fiber would: `bc2cpp_fiber_define` (called from `bc2cpp_resumable_init` and every Fiber
site) defines `Fiber`, `FiberError` and `Fiber.yield` (a yield across a C frame inside a fiber, or outside any fiber, raises
`FiberError` as mruby-fiber's does), beside `Fiber.new`/`resume`/`alive?`/`current`. `vm_bytecode_free_check` runs the check
and then reads the closed build's `bytecode-inventory.json`.

## What blocks removing mruby-fiber from the closed build

1. **The gems.** `build_config.rb` lists `mruby-fiber` unconditionally (line 272, and `explicit_shared_names`, line 460);
   `mruby-stringio` is in the same shared list and depends on `mruby-enumerator`, which depends on `mruby-fiber`
   (`mruby-set`, `mruby-enum-chain`, `mruby-enum-lazy` too), so the closed build cannot drop mruby-fiber without dropping
   StringIO and Enumerator. `mruby-rpgxp` (`script_host.rb`: the driver Fiber of the bundled main loop) and `mruby-wolf`
   (`interpreter.rb`: `@fiber = Fiber.new { execute }`) depend on it and use `Fiber.new`/`Fiber.yield`; the RPGXP script
   host runs eval-free but interpreted Ruby, so its Fiber bodies are not compiled. No build-config change is safe before
   these are settled, so none is made.
2. **Enumerator** (done in the `native_fiber_check` no-fiber build). `Enumerator#next`/`peek`/`lazy` need `mruby-enumerator`,
   which declares `add_dependency 'mruby-fiber'` in the submodule (not editable). mruby's resolver accepts any gem *named*
   `mruby-fiber` that the build lists first, so `NOFIBER_CORE_CONFIG` lists a placeholder gem first
   (`NOFIBER_PLACEHOLDER_GEM`, an `mrbgem.rake` with no sources, written into the build directory by `nofiber_or_build`).
   `mruby-enumerator`, `mruby-set`, `mruby-enum-chain`, `mruby-enum-lazy` and `mruby-stringio` then build without the real
   Fiber; the libmruby has no `mrb_fiber_*` symbols (the check asserts it) and `NOFIBER_GEMS` is only `mruby-fiber` and
   `mruby-os-memsize`. The gem's own `Enumerator#next` bytecode would call `Fiber.new` interpreted, so the program compiles the
   gem's mrblib (`mruby-enumerator` is in the probe's core gems, and `BC2CPP_ENUMERATOR_FIBER`, on by default, turns
   `next_values` into a step). mruby-enum-lazy is not among the gems bc2cpp compiles for the real closed build, so the probe
   passes its `lazy.rb` as extra source under a `3rd/mruby/mrbgems/mruby-enum-lazy/mrblib/` path, so it counts as mruby's own Ruby (as a program definition, its `map`/`select`/`each`... would withdraw the kind_of block arms of those names, and the scenario then crossed a C function boundary: `FiberError`): the closed world then defines `Enumerable#lazy` and `Enumerator::Lazy`
   (without it the scenario raised `closed-world proof violated: NativeFiberSource#lazy was proven undefined but dispatched`).
   The 'enumerator lazy nested' scenario now prints what interpreted mruby-fiber prints and `KNOWN_GAPS` is empty.
   Not done: the real closed build (`build_config.rb`) still lists the real `mruby-fiber`; this is the fixture's build only.
3. **Behaviour the scenarios exercise that the C++ Fiber lacks** (the `KNOWN_GAPS`): a closure that outlives the frame
   that made it ('escaping closure': a block step reads its builder's locals by pointer, valid only while that frame is on
   the fiber's stack; an escaping proc needs boxed variables); a `Fiber.new` inside a Fiber body (not a
   C++ Fiber: `resume` on it raises 'not a fiber'). `ensure`/`rescue` around a yield, `catch`/`throw` after a yield and a
   user `each` with optional, rest and keyword parameters are done (see STEP_HANDLERS and STEP_KEYWORDS).
4. **A `Fiber.new(&blk)` or a Fiber made through `send`** has no compiled path: only a literal-block `Fiber.new` site
   becomes a C++ Fiber.

Still failing:

- `resumable_variants_check` has no known gaps left.
