# 0273. bc2cpp: inlined step loops, and resumable compiled Fiber roots

Date: 2026-09-30

## Status

Accepted

## Context

`Optcarrot::PPU#main_loop` (the emulator's hottest method) runs inside a Fiber and yields every
few dot clocks through tiny helpers (`wait_one_clock`, ...) that call `Fiber.yield`, from inside
thirteen `341.step(589, 8) do ... end` style loops. bc2cpp refuses every method that reaches
`Fiber.yield` or that is reachable from a `Fiber.new` block (ADR 0269, `tools/optcarrot_probe/
README.md`): a compiled frame between the fiber's entry and the yield breaks mruby's fiber
switch, so the whole call tree of the Fiber stayed bytecode.

## Decision

### Inlined `Integer#step` / `#upto` / `#downto` (STEP_LOOP_SUPPORT)

`recv.step(limit, step) { |i| }`, `recv.upto(limit)` and `recv.downto(limit)` join the inlined
loop passes (`INLINE_LOOP_PASSES`) when the receiver and limit are provably Integers and the
`step` of `#step` is a non-zero literal. Proof is a `LOADI` literal with no jump between it and
the call, or `proven_fixnum_operand?` (FIXNUM_OPERAND_PROOF). Anything else (Float operands,
`Range#step`, a computed step, no block) keeps the block call, which also keeps the
`ArgumentError` for a zero step and the Float semantics of mrblib's `Float#step`. The loop is
mrblib's `while i <= num` (`>=` for a negative step) over a `long long` counter, so `i += step`
cannot wrap a 32-bit `mrb_int` (the bounds are fixnums), and it returns the receiver.

### Resumable Fiber roots (RESUMABLE_ROOTS, RESUMABLE_ENTRY)

The Fiber never crosses a compiled frame. A method `M` that a `Fiber.new { M; ... }` block
body calls directly on self (a *root*) and that reaches `Fiber.yield` is compiled as a **step
function** instead of being refused:

- Every register, every inlined-loop counter and the state number of the last yield live in a
  heap **frame**: an `RData` (class `Bc2cppResumable::Frame`) whose payload holds the state and
  the counters and whose hidden ivar holds an `RArray` of the `mrb_value` registers. The GC marks
  that array; each yield ends with `mrb_write_barrier` on it, so a frame that was already marked
  black is scanned again. The generated code names the registers `r0..rN` as C++ references into
  the array, so all existing instruction code works unchanged.
- The step function starts with `switch (state)` jumping to the label placed just after each
  yield point. Because nothing but the frame survives a return, the method body is flat: `while`
  loops and jumps are `goto`s, an inlined step loop keeps its counter in a frame slot, and a
  yielding helper (`wait_one_clock`) is expanded at each call site with its registers appended
  to the frame and its jump labels prefixed per site. A yield returns the frame (the yielded
  value in slot 0); returning anything else is the method's final value and clears the frame.
- The registered entry (`_impl`) is called by the interpreted Fiber block like any method.
  When it was called straight from the VM (`ci->cci == 0`, no arguments) it stores a cfunc
  Proc of the step function in the block slot and replaces its own frame by the bytecode of
  `Bc2cppResumable#drive` with `mrb_exec_irep`, the mechanism ADR 0269 uses. The driver is a
  few lines of Ruby compiled by the same `mrbc` and embedded as a byte array:

      f = step.call(self, nil, nil)
      while Bc2cppResumable::Frame === f
        f = step.call(self, f, Fiber.yield(f.value))
      end
      f

  (spelled with `::`: the first entry loads it from inside a running method, where a bare
  `module` nests under that method's class) so `Fiber.yield` runs in bytecode with no compiled
  frame beneath it, and the yielded and the resumed values round trip. When the entry is reached through a C frame (`mrb_funcall`,
  `send` from compiled code, an iterator implemented in C) the bytecode could not have yielded
  either: the entry steps in C++ and hands a yield to the real `Fiber.yield`, which raises the
  same `FiberError` as the interpreted method.
- The root Fiber block is not rewritten. It stays the bytecode `SSEND :main_loop; LOADSYM
  :done; RETURN`, which is why the design needs no shape match on the `Fiber.new` site and
  works for any bytecode caller.

**Eligibility.** The root takes no arguments or block and has no rescue/ensure handler. Every
`Fiber.yield` has 0 or 1 argument. A call to another method that can reach `Fiber.yield`
(`compute_fiber_yield_names`, by name over every receiver) must be a self call to the only
definition of that name, in the same class, without arguments, blocks or handlers, at most
`RESUMABLE_HELPER_DEPTH` deep and not recursive; it is inlined. A yield may sit in the method's
own instructions and in the body of an inlined step/upto/downto loop, never in another kind of
inlined loop or in a block that becomes a separate function (a `#error` naming the reason is
emitted and bc2cpp logs `bc2cpp: resumable: Owner#name stays interpreted: <reason>`; the method
then behaves exactly as before this ADR). A step loop nested inside another inlined loop body is
not inlined (the inner block stays a block function), so it cannot contain a yield. A block that
is a separate function and returns from the method is refused (its `return` is a C++ exception
caught around the whole body, and a `goto` cannot enter a `try`).

**Which methods are still refused.** FIBER_REACHABILITY_UNSAFE_SUPPORT refused every method a
`Fiber.new` block reaches by same-class self calls. Only a method that can itself reach
`Fiber.yield` has a yield above its native frame, so now only those are refused (or, for a
qualifying root, resumable); the callees that cannot yield (`open_name`, `render_pixel`, ...)
compile and are called directly from the step function. The by-name reach of `Fiber.yield`
stops at a `Fiber.new` block: a yield there returns to that fiber's `resume`, so the method
that builds the fiber (`PPU#run`, which stays interpreted because it builds a Proc for
`Fiber.new`) is not above it, and neither are its callers.

## Consequences

- `main_loop`-shaped code runs as native code between yields. The price is that its registers
  and loop counters are memory (a heap array) instead of C++ locals.
- Each resume costs the fiber switch plus one `Proc#call` into the step function and one
  `Frame#value`; the compiled body between two yields does not depend on the interpreter.
- The frame is created by the first step and freed by the GC after the last one (the finished
  step clears its registers so it does not keep objects alive). A Fiber that is abandoned
  mid-run leaves a frame that the GC collects with the Fiber.
- 32-bit `mrb_int`: the state, the register count and the counters are `mrb_int`/`long long`
  values that never leave C++, and no bignum crosses a C conversion; the loop bounds are
  fixnum-checked at compile time.
- Known limits: zero-argument roots only; yields with two or more arguments, yields in
  nested/other inlined loops, in rescue/ensure and in non-inlined blocks stay interpreted;
  `Method#arity` and friends read as for every compiled method; nothing here is exercised by a
  32-bit `mrb_int` CI build.
- Verification: `scripts/bc2cpp_step_inline_check.rb` and `scripts/bc2cpp_resumable_check.rb`
  compile fixtures, link them into a full-core mruby and require the compiled run to print what
  the interpreted run prints, including an incremental-GC-stress pass.
