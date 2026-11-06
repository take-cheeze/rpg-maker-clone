# bc2cpp: all compiled C++, no VM dependency

Status: plan (not started). Scope chosen: option 2, the full runtime. Fibers and blocks follow the
phases below. This page is the reference for each phase's exit criteria.

## Goal

The closed RPG2k build runs every method, block, Fiber and exception as compiled C++. The mruby VM
(`3rd/mruby/src/vm.c`, the `mruby-fiber` context switch, `exec_irep`, the call-info stack) is no longer
on any execution path. The object model (`mrb_value`, RString, RArray, RHash, the GC) stays, since the
closed build needs it for the game's data.

## What depends on the VM today

Measured in the generated closed-build sources (`build-closed-bc2cpp/closed/mrbgems/*/*.cpp`):

| Dependency | Sites | Replacement |
| --- | ---: | --- |
| `mrb_funcall` text matches | 683 | see the breakdown below |
| `bc2cpp_owner_call` (owner-listed dispatch) | 1746 | already direct; becomes a plain switch |
| `mrb_proc_new_cfunc_with_env` (block procs) | 391 | C++ block objects with captured env |
| `mrb_protect` (exception boundaries) | 167 | C++ `try`/`catch` on a typed exception |
| `mrb_gc_protect` (arena roots) | 142 | scoped C++ roots |
| `mrb_yield` / `mrb_funcall_with_block` | 24 | direct block invocation |
| `mrb_method_search_vm` | 37 | static method tables |
| `bc2cpp_resumable_exec` (VM driver entry) | 19 | C++ resume loop (already a step function) |
| `mrb_exec_irep` | 2 | removed with the frame machine |
| `mruby-fiber` context switch | Fiber bodies, `Enumerator#next` | C++ coroutine steps |

`vm.c` is 3919 lines, `fiber.c` 574, `gc.c` 1755 (kept, minus the VM roots).

Breakdown of the 683 `mrb_funcall` matches (generated closed-build sources, including comments):

- ~351: the bigint `==` arm of every `!=` site (`codegen_native_send.rb`, under `MRB_USE_BIGINT`). Compiled into each
  site, taken only for bigint receivers. Replace with a direct bigint equality call.
- ~170: self-sends by name in class bodies (`bc2cpp_ssend_args`, `codegen_class_body.rb`), taken when the callee is not
  proven statically. Replace with per-class dispatch tables (Phase 1).
- ~28: error reporting (`puts` on stderr, `bc2cpp.rb` error handler). Outside the hot path; keep or use a C++ print.
- ~26: generic dispatch helpers (`mrb_funcall_argv(recv, mid, ...)`, `mrb_funcall_with_block`). Phase 1.
- The rest are comment text (the `MONO ... no mrb_funcall` notes).

## Phases

Each phase lands behind a gate, is verified by the fixture checks, and must not regress the default
build. The host sweep and the verify build run at each phase's end.

### Phase 0: inventory and checks

- List every VM entry point the closed build reaches: the table above, plus `mrb_vm_run`,
  `mrb_run`, the call-info helpers, and what `mrblib` Ruby the closed build keeps.
- Add one check, `vm_free_inventory_check.rb`, that counts each dependency in the generated
  sources and fails when a count grows. The baseline is the table above.
- Exit: the check passes on the current tree, and the table matches the generated sources.

### Phase 1: direct dispatch everywhere

- Replace every `mrb_funcall` site with the owner-listed direct call, or with a per-class dispatch
  switch when the receiver is not statically known. The switch covers every class with a method of
  that name, and an unknown class raises `NoMethodError` in C++.
- Exit: `mrb_funcall` count is zero in the closed build; the fixture checks and the host sweep pass.

### Phase 2: C++ blocks and procs

- A block is a C++ object (a function pointer and a captured env struct), not an `RProc` with an
  `REnv`. `Proc#call` and `yield` call it directly.
- Escaping blocks (a `Fiber.new` body, a stored `&block`) keep an `RProc` wrapper that points at the
  C++ object. The wrapper holds the object alive through the GC.
- Exit: `mrb_proc_new_cfunc_with_env` count is zero in the closed build; `stack_block_check` and
  `resumable_variants_check` pass under both layouts (`BC2CPP_STACK_BLOCK_STACK` included).

### Phase 3: exceptions in C++

- `raise` throws a typed C++ exception carrying the Ruby exception object. `rescue` / `ensure` are C++
  `try` / `catch` / a scope guard. `mrb_protect` is replaced in each use.
- `break` and non-local `return` already use C++ throws (`bc2cpp_block_break`); they share the same
  mechanism.
- Exit: `mrb_protect` count is zero; `scripts/bc2cpp/` exception checks pass.

### Phase 4: Fibers as C++ coroutines

- Every method or block that can yield compiles to a resumable step (the existing `_rsm` form,
  generalised). A call from one step into another is a call-frame push, not a C call. This is option (a)
  in `docs/bc2cpp-resumable-block-calls.md`, now required.
- A Fiber is a C++ object holding its step stack. `Fiber#resume` runs the top step; `Fiber.yield`
  returns to the resumer. `mruby-fiber` is no longer linked.
- `Enumerator#next` uses the same coroutine.
- Exit: `native_fiber_check`, `resumable_variants_check`, `resumable_receiver_check` and
  `vm_bytecode_free_check` pass in the default build, with no `FiberError` from compiled code.

### Phase 5: delete the VM

- Remove `vm.c`, the `mruby-fiber` context code, `exec_irep`, the call-info stack and the bytecode
  dispatch from the closed build. The native VM (`native_vm.rb`) is removed with them.
- Exit: `nm` on the closed `libmruby.a` shows no `mrb_vm_run`, `mrb_exec_irep`, `mrb_fiber_*` or
  `mrb_funcall` symbols; the closed build links without `vm.c`.

### Phase 6: verify

- Full closed build, host sweep (every map, scenarios, the verify build), ASan run of the trace host,
  and the Fiber checks in CI.
- Exit: CI green on the PR head with the VM objects removed from the link.

## Risks and open decisions

- **mrblib Ruby in core.** Some core classes are Ruby (`mrblib/*.rb`). Each one that stays needs a C++
  body or a compiled body in the closed build. Decide per class; the inventory check lists them.
- **Object model and GC.** The plan keeps `mrb_value` and the GC. A roots-only GC without the VM stack
  needs its roots rewritten (Phase 2 and 3 cover this); confirm the arena model still works.
- **C API for other gems.** The closed build does not need mruby's C API for user code. Other build
  targets keep `vm.c`; the removal applies to the closed target only.
- **Estimated size.** Phases 1 to 3 are the bulk of the codegen work; Phase 4 is the largest single
  change because it touches every resumable step. Phases 0 and 5 are small.

## Order of work

0 (inventory) first, since it fixes the baseline. Then 1 and 2 together, since blocks and dispatch
share call sites. Phase 3, then Phase 4, then Phase 5. Each phase is one or more PRs, not one large
change.
