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
| `mrb_funcall*` | 99 | breakdown below |
| `bc2cpp_funcall_argv`, `_ssend`, `_funcall_kw` (by-name helpers) | 60 | helper copies per unit; no keyword site exists |
| `bc2cpp_owner_call*` (owner-listed dispatch) | 2377 | already direct; table-driven later, see Phase 1 |
| `mrb_proc_new_cfunc_with_env*` (block procs) | 5 | C++ block objects with captured env |
| `mrb_protect*` (exception boundaries) | 10 | `gem_init.c`, mruby headers (the host entry boundary is a typed catch) |
| `mrb_gc_protect*` (arena roots) | 20 | one `bc2cpp_root` per unit, `*_entry.h`, mruby headers |
| `mrb_yield*` | 14 | direct block invocation |
| `mrb_method_search_vm*` | 5 | one seam (`bc2cpp_find_method`); static tables go behind it |
| `mrb_exec_irep*` | 1 | mruby header; removed with the frame machine |
| `bc2cpp_resumable_exec*` | 0 | done |

`mrb_funcall` breakdown (the rest is in headers):
- Done (354 sites): the bigint `==` arm of every `!=` site (`codegen_native_send.rb`, `MRB_USE_BIGINT`) calls the shared
  `bc2cpp_bigint_eq` (`mrb_bint_cmp`), with no by-name send.
- Done (172 sites): class-body `include` and `attr_*` call `bc2cpp_mod_include` (`mrb_include_module`) and `bc2cpp_mod_attr`
  (mruby's own ivar cfuncs via `mrb_define_method_raw`), no by-name send. Only the `included` hook is still sent.
- Done: core `x.call(*args)` (`bc2cpp_proc_call_argv`) looks `call` up once and runs the found method (visibility as
  OP_SEND, a missing method through method_missing); the 4 error-path `puts` are one `bc2cpp_stderr_report` (a direct IO
  write when `$stderr#puts` is the gem's, else one by-name `puts`); `Fiber.yield` from C is one `bc2cpp_fiber_yield_c`.
- Done: the Proc `arity`/`parameters` stand-in calls `mrb_proc_arity` and the original `parameters` cfunc directly, the
  inlined `loop` and the no-method path send through `bc2cpp_funcall_argv`, `mrb_funcall_with_method` is declared once, and
  generated per-site notes say "by-name send" (90 of the old 243 were those notes).
- Done: a run-time sized `recv.m(*list)` is the owner call over the Array's items (`splat_owner_call_line`) when the
  closed world names every answerer, and `NativeOwnerMap` reads `M->array_class` like `mrb->array_class`, so mruby-rgss's
  captured `_rgss_native_sort!` has an owner. By-name body sites with `bc2cpp_funcall_argv`: 22 to 2; with
  `mrb_funcall_with_block`: 6 to 4.
- Measured 99 (13 are in mruby's own headers). Host sweep (7 scenarios and 543 maps, `--wrap` counters on `mrb_funcall_*`
  in a scratch link): by-name sends from generated code were 11.2k for `_rgss_native_sort!`, 8.8k for `IO.open`'s
  `new(*args)` and 101 for `Hash#__merge`, now 0; the load-time `included` hook (8.3k) is left, against 142M
  frame pushes (`mrb_funcall_with_method`). The larger by-name runtime counts are mruby's own hooks and `mrb_equal`
  (`const_added`, `hash`, `method_removed`, `==`, `initialize_copy`: 0.1M to 0.7M each), not sites in this tree.
- Done: `read_font` (mruby-rgss) runs the Font reader it finds; the fork's `==`/`eql?`/`<=>`, `Class#new` and
  `mrb_obj_new` run the method a memo found (`mrb_funcall_with_method`, `mrb_funcall_send_with_method`). Left by name in
  the sweep: the `included` hook, `IO.sysopen`, `Symbol#to_proc` and `convert_type` (the name is data), the host's taps.
- No keyword-carrying by-name site exists (`bc2cpp_funcall_kw` is an unused helper per unit). Left: the frame push (40),
  the helper copies, error paths that dispatch the real call to verify a proof, the `$stderr#puts` fallback, 3 entry-stub
  fallbacks (a receiver that is not the exact owner needs the generic send), 4 `_rsm` and fiber-park block sends, and 386
  `bc2cpp_send` sites in the core unit (no program world there, so no owner set; none ran in the sweep).

## Phases

Each phase must not regress the default build; the host sweep and the verify build run at its end. Order: 1 and 2
together (they share call sites), then 3, then 5.

### Phase 0: inventory and checks

Status: done. `scripts/bc2cpp/vm_free_inventory_check.rb <closed-build-dir>` fails above the table's baselines.
Registered in `bc2cpp-build`.

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

Status: stages 1 to 3 done. `Bc2cppBlock` (`docs/bc2cpp-stack-blocks.md`) is the block as a C++ value: allocation-free in the frame by default
(it was 3 `calloc`s per execution; ASan and `BC2CPP_STACK_BLOCK_MALLOC` builds still malloc), also for a nested block that yields to the method's block and for a block that
breaks or returns (a cfunc entry over the same env), with `proc()` as the one lazy
RProc wrapper (the `Bc2cppHeapBlock` sites, 297, are gone). Stage 2: `bc2cpp_heap_proc` 98 (was 178), `bc2cpp_yield_foreign` 27, 483 frame-local sites (was 393):
`BlockSelf` proves `args[0]` windows and rescue/ensure yielders, a break/return block takes the frame-local form (45 sites), and a callee whose nested block
outlives the call (`Enumerator.new`, `Hash.new`) gets a heap block. Stage 3 (fresh closed build):
a callee may forward its block with `&blk` (every forwarding glue passes `bc2cpp_env_block` of it, a direct arm that only calls the block takes it as is):
`bc2cpp_heap_proc` 96, 485 frame-local sites.
Remaining heap blocks (96): 16 in the preamble, 59 in step frames (a parked step outlives the C++ frame), 14 by-name sends
(`new`, `permutation`, `sort`: the VM sees the block), 4 lambdas that escape into registers, and 3 direct calls to callees the
proof refuses (`__send__` with keywords, `!block`, a boxed nested block). Not done: the callee ABI (`mrb_value` block parameter)
and `bc2cpp_owner_call` taking a block value. Stores in callees would need `.proc()`, and `mrb_funcall_with_method` hands the
block to a VM frame, so neither moves a count before the VM-free call path.

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

Status: done for the link. The closed build no longer links vm.c: `NativeVM.configure` (`tools/bc2cpp/native_vm_build.rb`) drops
`vm-cxx.o` from `libmruby_core_objs` and compiles `tools/bc2cpp/runtime/vm_frames.cxx` (11.5 KB text; was 16.0 KB) in its place.
It is vm.c's frames, funcall, yield, `mrb_protect_error` and ci accessors for native callees, plus a fast path in
`mrb_funcall_with_method`. `mrb_vm_exec`/`run`/`top_run`/`load_proc`/`yield_cont`/`object_exec`/`stack_extend` and three ci setters
have no definition (nothing in the link used them; a new caller fails to link). `mrb_exec_irep` stays for `proc.o` and raises
"bytecode interpreter is not built in (frames-only runtime)" for an irep proc, as do funcall/yield on one and `send`/`eval` in a
`CINFO_NONE` frame; `host_sweep` fails on that message. Pinned by `frames_only_check.rb` and `vm_unreachable_check.rb`.
Other targets (wasm, Maix, Android, wio, host, fixture libraries) keep vm.c.

Measured with counters in a scratch vm.c (not committed), `4465dae`, 550 host processes (7 scenarios, 543 maps), callee by symbol:

| entry | callee | caller | pushes |
|---|---|---|---|
| `funcall_with_method` | native cfunc: `String#<<` 37.4M, `StringIO#getbyte` 33.6M, `Array#pack` 25.4M, `StringIO#eof?` 12.4M, `IO#getbyte` 9.3M, `StringIO#read` 8.1M, `IO#eof?`/`#read` 8.2M, rest 6.0M | generated `bc2cpp_owner_call` | 140.47M |
| `funcall_with_method` | compiled `_impl` wrapper | generated | 1.70M |
| by name, `funcall_send` | native cfunc (`mrb_equal`, boot hooks, `hash`, `initialize_copy`) | core C | 2.32M |
| by name, `funcall_send` | compiled wrapper | gem C, host | 0.13M |
| `yield_with_attr` | cfunc proc, compiled block thunk | generated | 3.22M |
| `exec_irep` | cfunc proc (`Proc#call`) | `proc.o` | 13K (1.1K on master since #3189) |

Irep procs, `method_missing` and `mrb_protect_error`: 0. Of `vm-cxx.o`'s 31 functions 21 are referenced by the link (core C,
`gem_init.o`, generated code), 10 by nothing (`ld --cref`), now undefined; the 21 are cfunc-only reimplementable.

The sweep passes without vm.c (plain, and `-fstack-protector-all` on the whole build). The frame ABI
stays (`mrb_get_args` reads `ci->stack`, gc marks ci), so this removes code, not the push: a map run of 292K pushes costs 1592.0M
instructions (callgrind), 1593.1M with the verbatim port, 1550.6M with the fast path (-2.6%, -142 per push). 94.6% of the 142M go
to those eight natives, all from LCF's byte readers; calling them directly from compiled code removes the push.

Remaining: (1) direct calls to the eight natives; (2) boot hooks `const_added`/`method_removed` (1.0M): skip the default no-op;
(3) `==`/`hash`/`initialize_copy` in core C (1.3M): look up once; (4) `Proc#call` from interpreted mrblib on a non-thunk fallback block (1,100 `exec_irep`, `RPG2k#read_ini_title`).
The copy of vm.c's frame code must follow fork changes to `cipop`/`protect_error`; the sweep guards it. optcarrot
(`tools/optcarrot_probe/compiled_run.rb`) is a separate full-core build, not VM-free, and does not run on master.

- Exit: `nm` on the closed `libmruby.a` shows no `mrb_vm_run`, `mrb_exec_irep` or `mrb_funcall` symbols; it links without `vm.c`.

### Phase 6: verify

Full closed build, host sweep, ASan trace host, Fiber checks in CI; green with the VM objects removed from the link. Today every
closed job runs without vm.c; the remaining exit is the direct calls above (the frame ABI itself stays).

## Risks

GC roots need rewriting without the VM stack (Phases 2 and 3). Other build targets keep `vm.c`.
