# bc2cpp: frame-local blocks for plain-yielder callees

A literal block whose body compiles without `break` or `return` has a direct
entry (BLOCK_DIRECT_ENTRY): a compiled callee's `yield` or `block.call` runs it
through `bc2cpp_yield_argv`, with no VM frame. The call site still built a
real `RProc` for it every time it ran: `mrb_proc_new_cfunc_with_env`, which
allocates an `RProc`, an `REnv` and a `malloc`'d copy of the env array.

`STACK_BLOCK` builds that `RProc` and `REnv` in the caller's frame instead
(`Bc2cppBlock`, in the runtime preamble of `tools/bc2cpp/bc2cpp.rb`), over
the env array the site already has. A direct core arm
(`BLOCK_CORE_DIRECT`, `codegen_block_core_direct.rb`) and a direct call to a
compiled program method (`direct_call_block`, `codegen_arg_shapes.rb`) pass it
when the callee only calls its block. The heap `RProc` is built only where the
code still dispatches by name: the other arms and the by-name else take
`bc2cpp_blk_stack_N.proc()`, which allocates when that branch runs.

## Why the frame-local block is safe

- **The callee cannot keep it.** `BlockSelf.plain_yielder_why`
  (`tools/bc2cpp/block_self.rb`) proves that the callee, and the blocks nested in
  it, only test, copy, `call` or `yield` the block, and never pass it as an
  argument or a block, return it, store it, or forward it with `super`.
- **The VM sees it only through a cfunc block.** In a compiled body, core or
  program, `block.call` and `yield` go to `bc2cpp_yield_argv`, which runs a
  non-strict `bc2cpp_block_thunk` proc through its direct entry. A block that
  breaks or returns has no direct entry: it is the same red `RProc` over its
  cfunc wrapper (`Bc2cppBlock(M, fn, len, env)`), and `bc2cpp_yield_foreign`
  runs it in a VM cfunc frame for the length of the call, as it does the heap
  one. A nested block of the callee reaches the block only through a captured
  slot, and calls it the same way.
- **A kept nested block means a heap block.** `keeps_captured_block?`
  (`codegen_block_core_direct.rb`): a callee with a nested block whose registers
  are boxed into a heap cells Array (`Enumerator.new`, `Hash.new`) or copied for
  a Fiber body gets the heap block, because the cells would hold the dead
  frame-local one. `block_abi_check.rb` has `kept_enum` and `kept_hash`.
- **The callee's nested blocks cannot keep it either.** A nested block that
  holds the method's block (a `yield` in it, or a captured `&b`) is compiled
  only when its own send is on the synchronous list or proven not to keep it
  (`recognize_block_fallback_regions`). Otherwise the callee is not compiled
  and the site has no direct call to pass the block to.
- **The GC never touches it.** Both objects are coloured `MRB_GC_RED`, the
  colour mruby gives ROM objects. `mrb_gc_mark` and `mrb_field_write_barrier`
  skip red objects, so a red object is never gray-listed or swept, even if a
  fallback path hands it to the VM for the length of a call.
- **Its env values stay alive.** The heap env marked the values it held. The
  frame-local env holds the caller's `self` and the `mrb_cptr_value` boxes of
  captured locals, created at the site and still in the GC arena while the call
  runs. A block that yields to the frame's own block (`needs_blk`) is left out:
  that forwarded value is one the heap env existed to root.
- **A heap env never holds it.** A nested block that yields to the method's block (`needs_blk`) is frame-local too when
  its callee only calls it, and its env holds the method's block as it is. `Bc2cppBlock::proc()` makes the heap wrapper
  for the arms that may keep the block and for the by-name else, and copies a frame-local block in the env slots
  (`bc2cpp_env_block`) so the heap env never holds a dead frame. A block built on the heap (no stack form) stores
  `bc2cpp_env_block(M, bc2cpp_blk)` as before. `stack_block_check.rb` (`use_repeat`) and `block_abi_check.rb` assert
  both; the RPG2k New Game under ASan reproduced the dangling mark (`LCF::Array2D#each`'s env) before the copy.

## Coverage

The proof reads every operand window the way the VM does. `reads_of` in
`tools/bc2cpp/block_self.rb` gives the count-sized operators their exact
registers (`ARRAY`, `ARRAY2`, `ARYPUSH`, `HASH`, `HASHADD`, `ARYCAT`, `HASHCAT`,
`STRCAT`, `ARYSPLAT`). A send reads its receiver, then one Array for a splat or
its positional arguments, then its keywords (one Hash for `**`), then its block.
`scripts/bc2cpp/plain_yielder_check.rb` holds the accepting and the refusing
cases for each shape. `GETIDX0` reads only its receiver (`args[0]`), and `RESCUE`
and `RAISEIF` read the exception and class registers. A callee that yields inside
a `rescue` or `ensure` is proven too: `reaching_definitions(handler_ops: true)`
lets the walk cross a handler's `EXCEPT` and `RESCUE` as vm.c runs them, and a
`RAISEIF` that falls through proves its register nil, so the handler edges into
the `EXCEPT` that stored it (the exception) are not followed.

Closed world (`scripts/bc2cpp/closed_build.bash`, all four compiled gems):

| Measure | Heap only | Frame-local | Exact windows |
| --- | ---: | ---: | ---: |
| block sites building the block in the frame | 0 | 220 | 309 |
| of these, never allocating an `RProc` | 0 | 25 | 37 |
| block sites always building a heap `RProc` | 438 | 218 | 129 |

By callee: `Array#each` 142, `Hash#each` 127, `Enumerable#collect` 118,
`Enumerable#each_with_index` 111, `Enumerable#any?` 54, `find_all` 24,
`Integer#times` 21, `Hash#select` 12, `Array#each_index` 9,
`Enumerable#reject` 8, `all?` 8, `each_with_object` 5, `Hash#reject` 4,
`Enumerable#uniq` 4, and a few more.

The proof still refuses the callees that pass their block on to another method:
`Range#each` (to `__upto_endless`), `Array#uniq` (to `uniq!`) and
`Enumerable#sort_by`.

## The C++ block (Phase 2, stage 1)

`Bc2cppBlock` is the block as a C++ value: the entry and the captured values (the site's env array) in the caller's
frame, as a red `RProc`/`REnv` pair laid out for `bc2cpp_block_thunk`, so it needs no allocation (it was three `calloc`s
per execution; ASan builds and `BC2CPP_STACK_BLOCK_MALLOC` keep malloc'd storage so a dangling reference is reported
with its free site). A callee that only calls its block takes `value()`; a direct-entry yield runs the entry with no VM
frame. The wrapper is `proc()`: the one place a stack block becomes a heap `RProc`, made where the block may be kept or
run by name (the by-name else, an arm whose callee passes its block on). Every escaping site still goes through
`bc2cpp_heap_proc`, and every VM yield of a proc that is not a compiled block through `bc2cpp_yield_foreign`; the
inventory check counts both. Not yet done: callee signatures still take the block as an `mrb_value` (the `value()` view
or a heap `RProc`), so a callee that forwards the block by `&blk` or stores it keeps the heap wrapper.

## Switch and check

`BC2CPP_STACK_BLOCKS=0` builds every block on the heap again.
`scripts/bc2cpp/stack_block_check.rb` asserts the generated shapes and compares
interpreted and compiled runs for captured-variable writes, nested callee
blocks, `GC.start` and allocation inside the block, an exception raised
through it, receivers that take the else, a program callee that yields, one
that stores its block and one whose nested block is stored, `GC.stress`, and
the same calls inside a Fiber.
