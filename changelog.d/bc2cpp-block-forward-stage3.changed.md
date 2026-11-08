- **bc2cpp** (Phase 2, stage 3): a compiled callee that only calls its block may also pass it on with `&blk`. Every
  forwarding send hands its callee `bc2cpp_env_block` of the block register (a frame-local block is copied to the heap
  there), and a direct arm whose callee only calls the block takes it as it is. On the closed build `bc2cpp_heap_proc`
  falls 98 to 96 and frame-local block sites rise 483 to 485 (`Game::State#to_lsd`'s `Actors#each` and `Range#first`'s `Range#each`).
  `block_abi_check.rb` runs the forwarding shapes interpreted and compiled, and `plain_yielder_check.rb` covers the proof.
