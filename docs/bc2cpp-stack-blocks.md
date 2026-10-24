# bc2cpp: frame-local blocks for plain-yielder callees

A literal block whose body compiles without `break` or `return` has a direct
entry (BLOCK_DIRECT_ENTRY): a compiled callee's `yield` or `block.call` runs it
through `bc2cpp_yield_argv`, with no VM frame. The call site still built a
real `RProc` for it every time it ran: `mrb_proc_new_cfunc_with_env`, which
allocates an `RProc`, an `REnv` and a `malloc`'d copy of the env array.

`STACK_BLOCK` builds that `RProc` and `REnv` in the caller's frame instead
(`Bc2cppStackBlock`, in the runtime preamble of `tools/bc2cpp/bc2cpp.rb`), over
the env array the site already has. A direct core arm
(`BLOCK_CORE_DIRECT`, `codegen_block_core_direct.rb`) passes it when its
compiled callee only calls its block. The heap `RProc` is built only where the
code still dispatches by name: the other arms and the by-name else take
`bc2cpp_blk_heap_N()`, which allocates when that branch runs.

## Why the frame-local block is safe

- **The callee cannot keep it.** `BlockSelf.plain_yielder_why`
  (`tools/bc2cpp/block_self.rb`) proves that the callee, and the blocks nested in
  it, only test, copy, `call` or `yield` the block, and never pass it as an
  argument or a block, return it, store it, or forward it with `super`.
- **The VM never sees it.** In a compiled core body, `block.call` and `yield`
  go to `bc2cpp_yield_argv`, which runs a non-strict `bc2cpp_block_thunk` proc
  through its direct entry. A nested block of the callee reaches it only
  through a captured slot, and calls it the same way.
- **The GC never touches it.** Both objects are coloured `MRB_GC_RED`, the
  colour mruby gives ROM objects. `mrb_gc_mark` and `mrb_field_write_barrier`
  skip red objects, so a red object is never gray-listed or swept, even if a
  fallback path hands it to the VM for the length of a call.
- **Its env values stay alive.** The heap env marked the values it held. The
  frame-local env holds the caller's `self` and the `mrb_cptr_value` boxes of
  captured locals, created at the site and still in the GC arena while the call
  runs. A block that yields to the frame's own block (`needs_blk`) is left out:
  that forwarded value is one the heap env existed to root.

## Coverage

Closed world (`scripts/bc2cpp/closed_build.bash`, all four compiled gems):

| Measure | Before | After |
| --- | ---: | ---: |
| block sites building the block in the frame | 0 | 220 |
| of these, never allocating an `RProc` | 0 | 25 |
| block sites always building a heap `RProc` | 438 | 218 |

By callee: `Array#each` 142, `Enumerable#each_with_index` 111,
`Integer#times` 21, `Array#each_index` 9, `Enumerable#each_with_object` 5,
`Enumerable#uniq` 4, `Hash#each_key` 2, and one each of `Integer#downto`,
`Hash#delete_if`, `Array#find` and `Array#collect!`.

The proof refuses the other common callees:

- `Enumerable#collect`, `find_all` and `reject`, `Array#reject!`, and
  `Hash#reject` and `select`: `reads_of` models an `ARRAY`/`HASH` operand
  window as every register from the lowest one up, so the block register is in
  it.
- `Enumerable#any?`, `all?`, `count` and `detect`: they call the block with a
  splat (`block.call(*val)`), whose `SEND n=*` the proof does not model.
- `Hash#each`, `Range#each`, `Array#uniq` and `sort_by`: they pass the block on
  to another method.

Modelling those two operand shapes would extend the stack block to the first
two groups.

## Switch and check

`BC2CPP_STACK_BLOCKS=0` builds every block on the heap again.
`scripts/bc2cpp/stack_block_check.rb` asserts the generated shapes and compares
interpreted and compiled runs for captured-variable writes, nested callee
blocks, `GC.start` and allocation inside the block, an exception raised
through it, receivers that take the else, `GC.stress`, and the same calls
inside a Fiber.
