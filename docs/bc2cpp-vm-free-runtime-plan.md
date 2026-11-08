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
| `mrb_funcall*` | 243 | breakdown below |
| `bc2cpp_owner_call*` (owner-listed dispatch) | 2229 | already direct; table-driven later, see Phase 1 |
| `mrb_proc_new_cfunc_with_env*` (block procs) | 5 | C++ block objects with captured env |
| `mrb_protect*` (exception boundaries) | 18 | host entry boundary (`*_entry.h`), `gem_init.c`, mruby headers |
| `mrb_gc_protect*` (arena roots) | 20 | one `bc2cpp_root` per unit, `*_entry.h`, mruby headers |
| `mrb_yield*` | 14 | direct block invocation |
| `mrb_method_search_vm*` | 5 | one seam (`bc2cpp_find_method`); static tables go behind it |
| `mrb_exec_irep*` | 5 | removed with the frame machine |
| `bc2cpp_resumable_exec*` | 0 | done |

`mrb_funcall` breakdown (the rest is in headers):
- Done (354 sites): the bigint `==` arm of every `!=` site (`codegen_native_send.rb`, `MRB_USE_BIGINT`) calls the shared
  `bc2cpp_bigint_eq` (`mrb_bint_cmp`), with no by-name send.
- Done (172 sites): class-body `include` and `attr_*` call `bc2cpp_mod_include` (`mrb_include_module`) and `bc2cpp_mod_attr`
  (mruby's own ivar cfuncs via `mrb_define_method_raw`), no by-name send. Only the `included` hook is still sent.
- Done: core `x.call(*args)` (`bc2cpp_proc_call_argv`) looks `call` up once and runs the found method (visibility as
  OP_SEND, a missing method through method_missing); the 4 error-path `puts` are one `bc2cpp_stderr_report` (a direct IO
  write when `$stderr#puts` is the gem's, else one by-name `puts`); `Fiber.yield` from C is one `bc2cpp_fiber_yield_c`.
- Measured about 243 (about 100 are comments): what is left is the frame-pushing primitive (`mrb_funcall_with_method`,
  shared by owner calls), one by-name helper per unknown receiver (`bc2cpp_funcall_argv`, `bc2cpp_ssend`, the Proc
  `arity`/`parameters` stand-in, `exc.result`, dynamic `send`), a few block-carrying `each`/`map` sends and 3 entry stubs.

## Phases

Each phase must not regress the default build; the host sweep and the verify build run at its end. Order: 1 and 2
together (they share call sites), then 3, then 5.

### Phase 0: inventory and checks

Status: done. `scripts/bc2cpp/vm_free_inventory_check.rb <closed-build-dir>` fails above the table's baselines.
Remaining: register it in CI once `bc2cpp-build` publishes the tree.

### Phase 1: direct dispatch everywhere

- Replace every `mrb_funcall` with the owner-listed direct call or a per-class dispatch switch (unknown class: C++
  `NoMethodError`). Remaining: all of the breakdown above.
- Lookup seam (done): every method-table lookup in generated code and in the Fiber runtime calls `bc2cpp_find_method`
  (the preamble, `bc2cpp.rb`); `mrb_method_search_vm` text sites 57 to 5 (one per unit, plus mruby's header). Lookup
  semantics are unchanged (singleton, include/prepend order, `method_missing`, visibility, undef), so
  `owner_lookup_shapes_check.rb` runs them interpreted and compiled.
- Owner calls (2229 text matches): 168 carry `BC2CPP_OWNERS_D` rows (a compiled entry
  called with no table search); the rest dispatch through the lookup and the per-site (class, argc) cache, which hits
  without any lookup. A site's owner set shrank from 336 to 88 bytes (the 32-slot seen list is allocated on the first
  miss): the closed build's generated `.data` is 458 KB, 396 KB less than before.
- Remaining for owner calls: a class-id switch needs a table that mruby's mutable method tables (`define_method`,
  `remove_method`, `include`) cannot invalidate, so it waits for the registration-time class table behind the seam, and
  the 2055 other sites keep one lookup on a cache miss.
- Registration-time table, investigated (no code change): a table needs a signal for every method-table write, and
  mruby 4 has none a build can observe without editing `3rd/mruby`. Writers are `mt_put`/`mt_del`/`include_module_at`
  (all `static` in `class.c`, so `--wrap` cannot see calls from inside `class.c`: `define_method`, `alias_method`,
  `undef_method`, `remove_method`, `include`/`prepend`/`extend`, `public`/`private`, `attr_*`, `module_function`);
  `MRB_USE_METHOD_LOOKUP_HOOK` fires on reads only. Wrapping the Ruby-visible mutators after boot misses C gems that
  call `mrb_define_method_raw` at run time (`Struct.new`, `Data.define`), so a global epoch would be unsound.
- What is sound today: `mrb->cache` is the invalidation oracle. mruby clears it per name (define, visibility, remove),
  wholesale (include, prepend) and per class (free), and the owner-call slot reuses its entry only while the cache holds
  the same one (`OWNER_CALL_ICACHE`). `owner_lookup_shapes_check.rb` now writes tables after warm-up (`define_method`,
  `remove_method`, `alias_method`, `undef_method`, include, prepend, extend, visibility, `method_missing`, singleton and
  core redefinition) and requires compiled == interpreted. Cost: a hit saves about 75 instructions per call against
  the full lookup and checks (callgrind, `Array#pack` loop, -O2: 2304 vs 2379 per iteration); a table of our own would
  not beat that hit.
- Closed world: the engine lint (`rpg2k-closed-world-lint.md`) forbids `define_method`, `alias`, `undef`,
  `remove_method`, `method_missing`, `eval` and `extend` outside `self`, and the baseline holds none of them, so the
  engine writes tables only in class bodies at load (`attr_*`, `include`, `public`/`private :x`). A method whose owners
  are all compiled is a direct call and a runtime redefinition of it is outside the contract.
  optcarrot `eval`s a generated CPU/PPU core only under its `opt_cpu`/`load_cpu` options (default off; not checked
  against the probe's settings).
- To make the table sound upstream: add `uint32_t mt_epoch` to `mrb_state` and increment it in `mc_clear_by_id`,
  `mrb_method_cache_clear` and `mrb_mc_clear_by_class` (class.c: the three invalidation points already cover every
  writer), so the seam compares one integer and drops the per-slot cache entry compare. Not applied.
- Exit: `mrb_funcall` count is zero; fixture checks and the host sweep pass.

### Phase 2: C++ blocks and procs

Status: stages 1 and 2 done. `Bc2cppBlock` (`docs/bc2cpp-stack-blocks.md`) is the block as a C++ value: allocation-free in the frame by default
(it was 3 `calloc`s per execution; ASan and `BC2CPP_STACK_BLOCK_MALLOC` builds still malloc), also for a nested block that yields to the method's block and for a block that
breaks or returns (a cfunc entry over the same env), with `proc()` as the one lazy
RProc wrapper (the `Bc2cppHeapBlock` sites, 297, are gone). Stage 2 (fresh closed build): `bc2cpp_heap_proc` 98 (was 178),
`bc2cpp_yield_foreign` 27, 483 frame-local sites (was 393): `BlockSelf` now proves `args[0]` windows and rescue/ensure yielders,
and a break/return block takes the frame-local form (45 sites). A callee whose nested block outlives the call (`Enumerator.new`, `Hash.new`)
now gets a heap block (a stage 1 use-after-free). Remaining: the callee ABI still takes an
`mrb_value` (so `&blk` forwarding and stores keep the heap RProc), and `bc2cpp_owner_call` takes an RProc.

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
