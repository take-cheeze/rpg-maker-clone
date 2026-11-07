- **bc2cpp block procs are built at one site**: every compiled block that still needs an `RProc` goes through
  `bc2cpp_heap_proc`, and every VM yield of a non-compiled proc through `bc2cpp_yield_foreign`, so the closed build's
  `mrb_proc_new_cfunc_with_env` count falls from 470 to 4 and `mrb_yield` from 27 to 8 (the inventory check counts
  the two helpers). A yielder with a `rescue` clause is now a plain yielder, so its callers pass a frame-local block
  (15 more sites). See `docs/bc2cpp-stack-blocks.md`.
