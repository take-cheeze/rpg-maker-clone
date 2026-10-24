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

The proof reads every operand window the way the VM does. `reads_of` in
`tools/bc2cpp/block_self.rb` gives the count-sized operators their exact
registers (`ARRAY`, `ARRAY2`, `ARYPUSH`, `HASH`, `HASHADD`, `ARYCAT`, `HASHCAT`,
`STRCAT`, `ARYSPLAT`). A send reads its receiver, then one Array for a splat or
its positional arguments, then its keywords (one Hash for `**`), then its block.
`scripts/bc2cpp/plain_yielder_check.rb` holds the accepting and the refusing
cases for each shape.

Closed world (`scripts/bc2cpp/closed_build.bash`, all four compiled gems):

| Measure | Heap only | Frame-local | Exact windows |
| --- | ---: | ---: | ---: |
| block sites building the block in the frame | 0 | 220 | 288 |
| of these, never allocating an `RProc` | 0 | 25 | 37 |
| block sites always building a heap `RProc` | 438 | 218 | 150 |

By callee: `Array#each` 142, `Hash#each` 127, `Enumerable#collect` 118,
`Enumerable#each_with_index` 111, `find_all` 24, `Integer#times` 21,
`Hash#select` 12, `Array#each_index` 9, `Enumerable#reject` 8, `all?` 8,
`each_with_object` 5, `Hash#reject` 4, `Enumerable#uniq` 4, `count` 3, and a
few more.

The proof still refuses the callees that pass their block on to another method:
`Range#each` (to `__upto_endless`), `Array#uniq` (to `uniq!`) and
`Enumerable#sort_by`.

## Switch and check

`BC2CPP_STACK_BLOCKS=0` builds every block on the heap again.
`scripts/bc2cpp/stack_block_check.rb` asserts the generated shapes and compares
interpreted and compiled runs for captured-variable writes, nested callee
blocks, `GC.start` and allocation inside the block, an exception raised
through it, receivers that take the else, `GC.stress`, and the same calls
inside a Fiber.
