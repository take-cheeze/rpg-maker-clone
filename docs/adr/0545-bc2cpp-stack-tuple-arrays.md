# 0545. bc2cpp: stack tuple arrays for short-lived literal Arrays of immediates

Date: 2026-10-22

## Status

Proposed

## Context

Every Array literal compiles to `mrb_ary_new_from_values` (codegen_insn.rb, `when 'ARRAY'`): a heap object,
a GC root for its lifetime, and an element store. Many literals are small tuples of immediates (`a = [1, 2]`,
`[0, 0]`, `[nil, true]`) that never leave the method: they are read back with a literal index, stored into
with a literal index, or measured with `size`. For those the heap object is pure overhead.

The escape analysis gives one verdict per creation site (`EscapeAnalysis::Analyzer#creation`, `tracked` = every
register that may hold the value). It does not say what a confined value may be replaced with, and it does
not know the element classes. Placing a value on the C++ stack is not safe in general: mruby roots a GC object
through the VM stack and the arena, and a C++ local holding a heap pointer is invisible to the collector. The
only elements that need no root are immediates: fixnums, nil, true, false and symbols. An immediate needs
no GC mark, so a C++ array of them is an ordinary local.

## Decision

A literal Array of 1..8 elements is placed in a per-site C++ buffer, `mrb_value bc2cpp_tup<idx>[n]`, when
every condition below holds. Each condition is checked and a failure refuses the site (the Array stays).

1. **Escape.** `creation(irep, idx)` is non-escaping.
2. **No closures.** The irep builds no BLOCK or LAMBDA. A non-escaping closure can still read the frame's
   registers by pointer (`read_by_closures`), and the buffer is not a register.
3. **No cycle.** The ARRAY is not on a CFG cycle (normal or handler edges). Then one frame creates it at most
   once, so the frame holds one instance and one buffer suffices. A loop-carried creation is refused; the
   buffer would need a liveness proof that the previous instance is dead at the next creation.
4. **Immediate elements.** Each element register's reaching definitions (`BytecodeIR.producers`, through
   handler edges, following MOVEs) are all `LOADNIL`, `LOADTRUE`, `LOADFALSE`, `LOADSYM`, or a `LOADI*` whose
   value is a fixnum (`LOADI32` by `loadi_proven_fixnum?`). A `LOADL` (a pooled literal: a Float, a bignum or a
   String constant), an argument, or a call result refuses.
5. **No Ruby redefinition.** No Ruby definition (`irep`, `copy_irep`, an installer, an ivar accessor) of `[]`,
   `[]=`, `size` or `length` reaches an exact Array (`World#defs_for`). Mruby's own natives may.
6. **Uses only.** For every register the verdict says may hold the array (the `tracked` set; a superset, so a
   register outside it cannot hold the array), every instruction that reads it is either a `MOVE` (a copy: the
   reaching definitions of the copy follow it back to the ARRAY), or one of the placed forms:
   - `GETIDX` / `GETIDX0` with a literal index (`LOADI*` is the one reaching definition): `R[a] = buf[k]` for
     `-n <= k < n`, `R[a] = nil` otherwise (Array#[] semantics for a fixed length);
   - `SETIDX` with a literal index in `0...n` and an immediate value: `buf[k] = v; R[a] = v`;
   - `SEND` `size` or `length` with no argument and no block: `R[a] = mrb_fixnum_value(n)`.

   Any other read of an instruction whose reaching definitions include the ARRAY refuses the site: a
   `JMPIF` on the array, a call argument, a store, a return, an element of another literal, a computed index.
   The read model (`stack_tuple_reads`) is a superset per opcode; an unmodelled opcode reads every tracked
   register.

The ARRAY itself compiles to the element copies followed by `R[d] = mrb_nil_value()`; a read through the
array's register is always one of the placed forms, so the nil never reaches a consumer.

### Placement and completeness

`stack_tuple_insn` runs as the outermost `compile_insn` (prepended last, `codegen_stack_tuples.rb`), so the
placed text is returned without the other wrappers (nilable receiver, class narrowing, reports) that would
otherwise wrap it with a nil arm or a class guard reading the frame register. `stack_tuple_visit` marks an
instruction whose text comes from a bypass path (suppressed, glued, or behind a guarded prefix), and a
resumable or shifted (`reg_offset != 0`) compile of a planned instruction is a bypass too.

The method is compiled under its plan. If any planned instruction was bypassed, or any planned instruction was
never compiled through the hook, the method is compiled again with no plan (`stack_tuple_compile_method`,
reported under `BC2CPP_STACK_TUPLES_REPORT=1`). The retry is the baseline output, so a refusal can never leave a
read of an unallocated buffer.

### Kill switch

`BC2CPP_STACK_TUPLES=0` returns every method to the earlier output byte for byte. It also requires
`BC2CPP_ESCAPE_ANALYSIS`: with the analysis off there is no verdict, so no plan.

## Consequences

- The array no longer exists for a placed literal: no `mrb_ary_new_from_values`, no GC root, no arena slot.
  The gain is per creation, not per method. It is not measured in this change (see Measurement).
- Refusals are the default. Loop-carried creations, creations whose elements come from calls or ivars,
  handler-table reads (no reaching definition through an exception edge), Float and bignum literals, closures,
  and any Ruby redefinition of the four methods all keep the Array. Each refusal is a line under the report
  variable, so the refused population is inspectable.
- The planner adds one producers query per (tracked register, reading instruction) pair. It runs only for
  ireps without closures that contain an ARRAY instruction. Its compile-time cost is not measured in this change.
- The retry doubles the compile of a method whose plan is incomplete. The completeness rule is the place where
  a new bypass path must be added: a new emitter that compiles a planned instruction without `compile_insn`
  makes the method refuse (safe), never silently read the frame register.

### Verification

`scripts/bc2cpp/stack_tuples_check.rb` (runtime tier, MRBC and the full-core build, as
`sealed_int16_local_check.rb`):

- placement: each positive method has its buffer; the literal-only methods build no mruby Array; the negative
  methods build none, and the whole negative output is byte-identical to `BC2CPP_STACK_TUPLES=0`;
- parity: every row (positive, negative, and a redefined `Array#size`) prints the same value interpreted and
  compiled, and each value equals the value the Ruby semantics give;
- a mutation (negative index mapping removed from the `:get` text) makes the parity rows fail, so the rows
  detect a wrong placed form.

Not covered: the closed world's own mrblib, which is compiled into `libmruby.a` and checked by the closed build
job; the 32-bit (`MRB_INT32`) build, where `LOADI32` immediates and the fixnum bound differ (`loadi_proven_fixnum?`
is the only place that decides it, and no check runs a 32-bit VM over these fixtures).

### Follow-up

- A liveness proof for loop-carried creations (the previous instance is dead at the back edge), which would lift
  refusal 3.
- Reaching definitions through handler edges for `rescue` bodies (refusal `no_producers`).
- Element kinds beyond immediates (Float, String constants) need GC roots, so they stay refused; a tuple of
  Floats could use an mruby stack-slot root instead.

### Measurement

The closed-world corpus counts (placed sites before and after) and the compile-time cost are not measured in
this change. The closed build could not complete in the authoring worktree: its `3rd/lvgl` submodule was not
initialised, so `mruby-rgss` failed on a missing `lvgl.h`. The build was stopped and not retried. CI's own
closed build measures both. The host check is the only evidence in this change.
