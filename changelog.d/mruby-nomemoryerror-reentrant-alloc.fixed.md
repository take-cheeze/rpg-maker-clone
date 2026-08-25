- **Vendored mruby: hardened two real gaps in `NoMemoryError` recovery.**
  Found chasing `docs/adr/0047-psp-memory-budget.md`'s P1c (a real
  `ppsspp-headless` segfault once the PSP's fixed mruby arena runs near
  full), via a host-native repro built against this project's own exact
  arena allocator. (1) The pre-allocated `NoMemoryError`/
  `SystemStackError`/arena-overflow singleton exceptions were never
  actually frozen, so raising one could still trigger a second, avoidable
  allocation (backtrace capture) at exactly the moment there was no room
  left -- now frozen, matching how `src/print.c`/`src/backtrace.c` already
  special-case them when printing. (2) `mrb_open()` could not tell
  `mrb_core_init_abort()`'s deliberate `mrb->exc = NULL` apart from genuine
  success, so an allocation failure early enough in bootstrap let it
  proceed into gem init on a half-initialized state instead of failing
  cleanly -- now also checks `mrb->c == NULL`. Both are real, verified
  fixes to upstream mruby's own logic (patched in place via
  `patches/mruby-nomemoryerror-reentrant-alloc.patch`, this submodule
  having no fork of its own to carry them on); the repro did not reproduce
  P1c's exact crash signature, so P1c itself remains open.
