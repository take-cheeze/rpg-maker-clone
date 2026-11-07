# bc2cpp: all compiled C++, no VM dependency

Status: Phases 0 and 4 done; 1, 2, 3, 5, 6 open. Scope: the full runtime. This page is the reference for each
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
| `mrb_protect*` (exception boundaries) | 199 | C++ `try`/`catch` on a typed exception |
| `mrb_gc_protect*` (arena roots) | 178 | scoped C++ roots |
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

- A block is a C++ object (function pointer plus captured env struct), not an `RProc` with an `REnv`; `Proc#call` and
  `yield` call it directly. Remaining: everything (471 `mrb_proc_new_cfunc_with_env`, 33 `mrb_yield`).
- Exit: `mrb_proc_new_cfunc_with_env` is zero; `stack_block_check` and `resumable_variants_check` pass under both
  layouts (`BC2CPP_STACK_BLOCK_STACK` included).

### Phase 3: exceptions in C++

- `raise` throws a typed C++ exception; `rescue`/`ensure` are `try`/`catch`/a scope guard (`break` and non-local
  `return` already throw: `bc2cpp_block_break`). Remaining: 199 `mrb_protect`, 178 `mrb_gc_protect`.
- Exit: `mrb_protect` is zero; the exception checks in `scripts/bc2cpp/` pass.

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
