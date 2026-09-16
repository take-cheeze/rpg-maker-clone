- `tools/bc2cpp/bc2cpp.rb` can now compile a `BLOCK`/`SENDB`/`SSENDB`
  region NOT recognized by any of the existing specific inliners
  (`.times`/`.each`/`.map`/`.select`/`.sort_by`/...) -- previously the
  single largest `#error` category by a wide margin (BLOCK 342 + SENDB
  319 + SSENDB 36, ~85% of all `#error`s whole-program). Rather than
  attempting to inline the block body the way the specific recognizers
  do, this compiles the block's own child irep as a genuine, standalone
  C++ function, wraps it in a real `RProc` (`mrb_proc_new_cfunc`), and
  dispatches the outer call dynamically (`mrb_funcall_with_block`) --
  landing as a NEW, explicitly tracked category
  (`BLOCK_FALLBACK`/`scripts/bc2cpp_coverage_report.rb`'s own new
  section), not folded into either the `#error` count or a fully-
  devirtualized one: every site here still dispatches dynamically, so
  whole-program devirtualization coverage is not actually complete for
  them the way an ordinary compiled-clean call site's own MONO/POLY/
  TYPED resolution already is.

  This is the first code this compiler has ever generated that
  constructs a real `Proc` object. Two real correctness hazards were
  found and designed around BEFORE writing any codegen, not discovered
  by a failing test afterward:
  - **`self` inside the block.** `mrb_proc_get_self`
    (3rd/mruby/src/proc.c) returns `self = nil` UNCONDITIONALLY for any
    CFUNC-backed proc, regardless of any `mrb_proc_new_cfunc_with_env`
    capture -- and that is exactly what native iterators
    (`Array#each`/`Hash#each`/...) call to determine a yielded block's
    own `self` (`mrb_yield`/`mrb_yield_argv`, 3rd/mruby/src/vm.c). A
    block that reads `self` -- implicitly (`@ivar`, an implicit-receiver
    call) or explicitly -- would silently run against `nil` at runtime
    if compiled this way. This is the same fundamental gap
    `recognize_times_regions`' own long-standing top comment already
    flags for a plain (non-cfunc) `mrb_proc_new` -- confirmed here that
    the cfunc variant has an equally real, independent version of it.
  - **Outer-local capture and non-local exit.** No real `REnv` register
    layout a `_with_env`-captured plain argv array can satisfy
    (`GETUPVAR`/`SETUPVAR`), and no plain C++ `return` equivalent for a
    non-local exit (`RETURN_BLK`/`BREAK`) once the block is a genuinely
    separate top-level function, possibly several C call frames deep
    inside whatever method is iterating.

  New pieces:
  - `block_fallback_safe?`/`BLOCK_FALLBACK_UNSAFE_OPS` -- the static
    proof that neither hazard applies: rejects on `GETIV`/`SETIV`
    (self access), `SSEND`/`SSEND0`/`SSENDB`/`SSENDB0` (implicit-self
    receiver, the one shape that doesn't spell out `self`'s own register
    literally), any bare `R0` token anywhere in the block's own
    instructions (`self`'s own register, real mruby calling convention
    -- one substring check catches every indirect reference, no
    dataflow trace needed), `GETUPVAR`/`SETUPVAR`, `RETURN_BLK`/`BREAK`,
    a nested `BLOCK`/`SENDB` (no recursive fallback support this
    round), and `RESCUE`/`RAISEIF`/`EXCEPT` (no rescue-region support in
    this standalone function). Only a `pure_mandatory_arity?` block
    body is considered at all.
  - `recognize_block_fallback_regions` -- the catch-all recognizer,
    intentionally unlike every named inliner it sits alongside: it
    names no specific method, firing for ANY qualifying block-carrying
    call the `suppressed` address set (compile_method's own existing
    region-tracking mechanism) shows no earlier, more specific
    recognizer already claimed. Deliberately `n=0`-only (no explicit
    positional args alongside the block): real `OP_SENDB`
    (3rd/mruby/src/vm.c) places the block register at `a + c + 1`, so
    the `BLOCK R(a+1)` adjacency every recognizer in this file
    (including this one) checks is only a confirmed-sound layout when
    `c == 0` -- never independently exercised for `n>0` anywhere in this
    file; combining with a real positional arg list is a natural
    follow-up, not this round's scope.
  - `emit_block_fallback_fn`/`emit_block_fallback_glue` -- the standalone
    function pair (an `_impl` compiled via the exact same `compile_insn`
    every other emitter here reuses, plus a real `mrb_func_t`-shaped
    cfunc entry using the identical `mrb_get_args`-based argument
    extraction `compile_method`'s own plain-mandatory-arity entry
    wrapper already uses) and the call-site glue
    (`mrb_proc_new_cfunc` + `mrb_funcall_with_block`). `self` is
    threaded through unused (block_fallback_safe? already proved it's
    never read) except to give `compile_insn`'s own GETCONST/lexical-
    scope codegen -- which still needs `owner_def`, the ENCLOSING
    method's own, since a block's lexical scope for constant resolution
    is always its enclosing method's -- a real declared identifier to
    match its own hardcoded `self`, exactly like
    `emit_rescue_try_body`'s own identical fix for the same constraint.

  A real bug was caught and fixed before this ever shipped, the same way
  idea 1's own splat-unroll round caught one: the first version named
  the generated function off `block_addr` alone, unique only WITHIN one
  irep -- two unrelated methods easily share a numeric bytecode offset,
  which would have emitted duplicate top-level C++ symbols across the
  whole generated file (a real link failure) the moment two different
  methods' own fallback blocks happened to collide. Fixed by prefixing
  with `cpp_name(d.owner, d.name)`, this whole program's own already-
  established globally-unique per-method key (every other `_impl`/entry
  function name here is already built from it), exactly matching
  `emit_rescue_try_body`'s own `"#{impl_name}_rescue_try#{i}"`
  convention for the identical constraint.

  Verified via a real whole-program regen (fresh, correctly-patched host
  `mrbc`): 36 real call sites compiled via this fallback (e.g.
  `Game::TextReveal#initialize`'s own `sort { |a, b| a[:at] <=> b[:at]
  }` -- a real comparator block `emit_sort_inline` itself explicitly
  declines, `Game::Battle#can_leave_front_row?`'s own `.reject { ... }`,
  `Game::Battle#enemy_active?`'s own `.any? { ... }`,
  `Game::Battle#turn_order`'s own `.sort_by { ... }` -- each on a
  receiver the specific inliners' own static Array-class gate couldn't
  prove, unlike this fallback, which needs no receiver-class proof at
  all since it dispatches dynamically). 16 methods move from `#error` to
  compiling clean (`compiled clean` 1972 -> 1988), whole-program `#error`
  total 811 -> 739 (BLOCK 342 -> 306, SENDB 319 -> 283, exactly 36
  fewer each, matching the 36 real regions one-for-one; SSENDB stayed at
  36 -- no qualifying self-implicit site fired this round, not a bug).
  Inspected the real generated code for multiple sites directly, not
  just the aggregate counts. `bash scripts/bc2cpp_coverage_check.bash`:
  fresh. `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), `scripts/lcf_testbed_check.rb`
  all still pass. A full whole-program `g++ -fsyntax-only` compile wasn't
  reachable in this session's own sandbox (no SDL2 devshell); instead,
  directly compiled a minimal `g++ -std=c++17 -fsyntax-only` smoke test
  reproducing the exact new `mrb_proc_new_cfunc`/`mrb_funcall_with_block`
  call shape against this repo's own real mruby headers -- clean.
