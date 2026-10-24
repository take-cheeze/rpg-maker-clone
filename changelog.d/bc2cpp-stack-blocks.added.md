- **bc2cpp: literal blocks passed to plain-yielder core bodies live in the
  caller's frame.** A direct-entry block handed to a compiled core arm whose
  callee only calls its block (`Array#each`, `Enumerable#each_with_index`,
  `Integer#times`, ...) is built as a frame-local, GC-red `RProc`/`REnv`
  instead of a heap `RProc`, `REnv` and env copy; the heap block is built only
  where the code still dispatches by name. In the closed world 220 of 438
  block sites take the frame-local block (25 never allocate).
  `BC2CPP_STACK_BLOCKS=0` restores the heap blocks. See
  `docs/bc2cpp-stack-blocks.md`; covered by
  `scripts/bc2cpp/stack_block_check.rb`.
