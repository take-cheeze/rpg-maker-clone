# bc2cpp: all compiled C++, no VM dependency

Status: Phases 0 and 4 done, 3 mostly done; 1, 2, 5, 6 open. Scope: the full runtime. This page is the reference for each
phase's exit criteria.

## Goal

The closed RPG2k build runs every method, block, Fiber and exception as compiled C++; the mruby VM (`vm.c`,
`exec_irep`, the call-info stack) is on no execution path. The object model (`mrb_value`, RString, RArray, RHash, GC)
stays.

## Where the closed build is now

- Loads no bytecode or Ruby source: `mrb_load_*`, `mrb_eval`, `mrb_vm_run` have no call sites; `mrblib` is dead code
  under `MRB_CORE_CLASS_UNITS`.
- `mruby-fiber` is not linked; Fiber and `Enumerator#next` run on the C++ Fiber (`docs/bc2cpp-cxx-fiber.md`).
- The VM left is about 16 KB in `vm-cxx.o` (`mrb_funcall*`, `mrb_yield*`, `mrb_protect_error`, `mrb_vm_ci_*`).

## What depends on the VM today

Text matches in the generated closed-build tree (`build-closed-bc2cpp/closed`, comments included; identifier prefixes
count, so suffixed names are included). These are the script's baselines.

| Dependency | Sites | Replacement |
| --- | ---: | --- |
| `mrb_funcall*` | 480 | breakdown below |
| `bc2cpp_owner_call*` (owner-listed dispatch) | 2208 | already direct; becomes a plain switch |
| `mrb_proc_new_cfunc_with_env*` (block procs) | 471 | C++ block objects with captured env |
| `mrb_protect*` (exception boundaries) | 18 | host entry boundary (`*_entry.h`), `gem_init.c`, mruby headers |
| `mrb_gc_protect*` (arena roots) | 16 | one `bc2cpp_root` per unit, `*_entry.h`, mruby headers |
| `mrb_yield*` | 33 | direct block invocation |
| `mrb_method_search_vm*` | 57 | static method tables |
| `mrb_exec_irep*` | 5 | removed with the frame machine |
| `bc2cpp_resumable_exec*` | 0 | done |

`mrb_funcall` breakdown (the rest is in headers):
- Done (354 sites): the bigint `==` arm of every `!=` site (`codegen_native_send.rb`, `MRB_USE_BIGINT`) calls the shared
  `bc2cpp_bigint_eq` (`mrb_bint_cmp`), with no by-name send.
- ~170: class-body self-sends (`include`, `attr_*`), run once at load. One `bc2cpp_ssend` helper call each; the callee is
  mruby's own C `Module#attr_*`, which has no public entry, so the by-name send inside the helper stays.
- ~70: core `x.call(*args)` now call `bc2cpp_proc_call_argv`: a plain Proc is yielded to, any other receiver is sent
  `call` by name inside the helper.
- 12: error-path `puts` (`bc2cpp.rb` error handler).
- The rest: Fiber and `each` helpers.

## Phases

Each phase must not regress the default build; the host sweep and the verify build run at its end. Order: 1 and 2
together (they share call sites), then 3, then 5.

### Phase 0: inventory and checks

Status: done. `scripts/bc2cpp/vm_free_inventory_check.rb <closed-build-dir>` fails above the table's baselines.
Remaining: register it in CI once `bc2cpp-build` publishes the tree.

### Phase 1: direct dispatch everywhere

- Replace every `mrb_funcall` with the owner-listed direct call or a per-class dispatch switch (unknown class: C++
  `NoMethodError`). Remaining: all of the breakdown above.
- Exit: `mrb_funcall` count is zero; fixture checks and the host sweep pass.

### Phase 2: C++ blocks and procs

Status: partly done. Block construction and the foreign-proc yield each have one site (`bc2cpp_heap_proc`,
`bc2cpp_yield_foreign`; `docs/bc2cpp-stack-blocks.md`), and 394 sites pass a frame-local block with no allocation. The closed
build's text counts: `mrb_proc_new_cfunc_with_env` 470 to 4, `mrb_yield` 27 to 8; the inventory check now also counts the
two helpers (166 and 27). What remains is the ABI: a compiled callee takes its block as an `mrb_value` RProc, so the 297
by-name else arms (`Bc2cppHeapBlock`) and about 130 sites that pass an escaping block (callee stores or forwards it, `break`
or `return` in the body, `&blk` forwarding, `dyn_call`) still allocate. Next: a C++ block value (entry plus env) that the callee
signatures take instead of `mrb_value`, with the RProc wrapper made only where the block is stored.

- Exit: `mrb_proc_new_cfunc_with_env` is zero; `stack_block_check` and `resumable_variants_check` pass under both
  layouts (`BC2CPP_STACK_BLOCK_STACK` included).

### Phase 3: exceptions in C++

Status: mostly done. The closed build uses `MRB_USE_CXX_EXCEPTION`, so mruby raises with `throw (mrb_jmpbuf*)`; a
boundary is a typed `catch (mrb_jmpbuf*)`, not a new exception class (mruby's own raise is the thrown type).

- Done: every rescue/ensure boundary in generated code (method and block rescue, the ensure guard and its nested
  rescue, step handler loops, the Fiber loop) calls `bc2cpp_protect` / `bc2cpp_protect_call` (`bc2cpp.rb`), one
  C++ `try`/`catch` that restores `M->jmp`, the call-info stack, the arena and `M->exc` as the VM's protect call did.
  Arena roots go through `bc2cpp_root` / `bc2cpp_arena_keep`; the numeric slow paths no longer expand their own.
  `break`/`return` through `ensure` still use the `bc2cpp_block_break` / `bc2cpp_method_return` throws.
- The counts fall because the boundary no longer calls the VM and the roots share one helper per unit, not because
  roots are gone. Not reducible: no rescue region is raise-free (all 144 try bodies contain a call that can raise), so none drops its
  boundary. Roots on freshly allocated or unlinked values stay arena roots.
- Remaining: the host entry boundary (`bc2cpp_entry_call`, `*_entry.h`) keeps the public protect API and root, since a
  host may not build with C++ exceptions; `gem_init.c` and mruby's headers are not generated. The exception object is
  still an `RObject` in `M->exc`, not a C++ value.
- Exit: the generated sources have no VM protect call; `scripts/bc2cpp/` exception checks pass
  (`protect_cxx_check.rb` runs the shapes interpreted and compiled, with GC stress).

### Phase 4: Fibers as C++ coroutines

Status: done. Fiber, `Enumerator#next` and `Fiber#transfer`/`#raise` run on the C++ Fiber; `mruby-fiber` is not linked.

### Phase 5: delete the VM

- Remove `vm.c`, `exec_irep`, the call-info stack and the bytecode dispatch from the closed build, and `native_vm.rb`.
- Remaining: the 16 KB in `vm-cxx.o` (goes with Phases 1 to 3), the 5 `mrb_exec_irep` declarations, 57
  `mrb_method_search_vm`.
- Exit: `nm` on the closed `libmruby.a` shows no `mrb_vm_run`, `mrb_exec_irep` or `mrb_funcall` symbols; it links
  without `vm.c`.

### Phase 6: verify

Full closed build, host sweep, ASan trace host, Fiber checks in CI; green with the VM objects removed from the link.

## Risks

GC roots need rewriting without the VM stack (Phases 2 and 3). Other build targets keep `vm.c`.
