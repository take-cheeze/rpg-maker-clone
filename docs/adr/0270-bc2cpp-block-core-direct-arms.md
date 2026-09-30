# 0270. bc2cpp calls compiled core block methods directly from literal-block sends

Date: 2026-09-30

## Status

Accepted

## Context

After ADR 0265 a literal-block send (`recv.each { ... }`) is a direct call only when the
compiler resolves the call to one compiled callee, which is 30 of the 453 such sites in the wio
closed-world build (`page_field`, `cached_bitmap`, `Actors#each`, ...). The other 423 build the
block's RProc and call `mrb_funcall_with_block`. Their callee names are the core iterators:
`each` 205, `map` 43, `each_with_index` 42, `any?` 20, `select` 13, `new` 12, `times` 10,
`section` 9, `each_index` 8; 343 sites are in engine methods and 80 in compiled core mrblib.

ADR 0264 compiles those iterators (`Array#each`, `Hash#each`, `Range#each`, `Enumerable#collect`,
`Integer#downto`, ...), and ADR 0269 puts each behind a Fiber guard in its registered entry. Two
rules kept every compile-time call site away from them:

- a guarded body is never a direct-call target (`compiles_clean?` answers false), because a
  direct `_impl` call skips the entry and so the guard;
- with a block in flight `poly_candidates` drops every chain arm whose callee takes a block,
  since a chain arm calls `_impl(M, recv, args)` with no block slot.

The receiver is rarely provable (`@events.each`, `h.each`), so the closed-world proof that
resolves an ADR 0265 site does not apply. What is provable is the receiver's *exact* class at
run time, the same shape ADR 0257 uses for core natives.

## Decision

**BLOCK_CORE_DIRECT** (`tools/bc2cpp/codegen_block_core_direct.rb`, prepended to `CodeGen`
like `NativeCoreDirectFallback`). In front of the block-carrying dynamic send of a literal-block
site in engine code, emit one arm per exact builtin receiver class (Array, Hash, Range, Integer):

    if (M->c == M->root_c && mrb_array_p(r) && mrb_obj_ptr(r)->c == M->array_class) {
      r = Array_each_impl(M, r, mrb_obj_value(bc2cpp_blk_proc_N));
    } else if (... Hash ...) { ... } else {
      r = mrb_funcall_with_block(M, r, :each, 0, NULL, mrb_obj_value(bc2cpp_blk_proc_N));
    }

The block is the RProc the site already builds; nothing about the block changes. The else is the
site's existing send, so every other receiver dispatches as before. `compile_direct_block_send`
already accepts a site whose direct calls all carry the block and whose remaining dispatch is
block-carrying; the arms go through `direct_call_args`, so they meet both conditions.

The target of an arm is found per class by walking its lookup order (`Array`, `Enumerable`;
`Hash`, `Enumerable`; `Range`, `Enumerable`; `Integer`, `Numeric`, `Comparable`) over the
compiled core definitions (`core_hidden_defs`, aliases included: `select` is `find_all`). An arm
exists only when all of these hold, each checked at compile time:

1. the site is in engine code of a closed world (`@closed_world`, not `@compiling_core`), with
   the native sources scanned;
2. on each owner up to and including the definition, no native registration names the method
   (`NativeExpressionDevirt.class_registrations`, opaque registrations included), no prepend or
   unattributed mixin, and no outside Ruby definer that is not core source
   (`ClosedWorld#core_ruby_arm_safe?`, `ForeignDefiners` over the outside paths minus mruby's
   own Ruby, which is what the arm calls);
3. no project definition of the name on the chain and no dynamic installer of the name;
4. the definition is unique, takes a block, has a signature `direct_call_args` models for the
   site's argument count, reads nothing of the caller's frame (`block_transparent_callee?`),
   compiles clean (`block_core_clean?`: `compiles_clean?` without the guard clause) and its owner
   is emitted by this link.

**The guard.** An arm repeats the entry's condition, `M->c == M->root_c`, so a Fiber's frames
still take the bytecode (ADR 0269). The entry's `bc2cpp_core_each_is_builtin` test for an
`Enumerable` body is a fact of the exact Array/Hash/Range classes named here. Exact-class guards
send subclasses and receivers with a singleton class to the dynamic else.

`Integer#times` and the other loops of ADR 0147-0156 are already inlined and do not reach the
arms.

**Where the arms are emitted.** Also in the compiled core bodies themselves (80 of the sites):
`compile_method` hides `@closed_world` from a core body's static-binding proofs, but the
outside-definer and installer facts are about the whole program, so it keeps the world in
`@core_program_world` for `block_core_world`. The block-taking core methods with an optional
argument or block (`find`, `sum`, `any?`, `all?`) count as modelled shapes
(`optional_block_callee?`), and a block nested in a block keeps its owning definition
(`emit_block_fallback_glue(..., owner_def:)`) so its sends see the same facts.

**Rest parameters are Arrays.** `dispatch_targets.rb#rest_entry_class` types the register that
holds a method's `*rest` at entry as `Array`; `xs.each { }` on it is the inlined loop of ADR
0147 or a direct call, not an arm.

## Consequences

- Wio closed-world report at this commit: of 448 literal-block sends, 376 are direct calls with
  the block (30 of ADR 0265 and 346 through arms), 72 dynamic only (was 423). The arms are `each` 112, `each_with_index` 38, `map` 34, `select` 13,
  `reject` 6, `each_index` 5, `sort_by` 4, `each_with_object` 4, `downto`/`times` 5, and a few more.
- The arm sites keep their POLY marker (the dynamic else is real), so the report's POLY counts
  grow by 346 although fewer calls dispatch: those sites were not in the diagnostics before. The
  report now prints the literal-block split next to them.
- What an arm saves: name lookup, the `mrb_funcall_with_block` frame, the entry wrapper's
  `mrb_get_args`, and the guard's cost is one comparison. Measured alone it is not visible in a
  loop; the per-yield cost is what ADR 0271 removes.
- Nothing changes when the build compiles no core (hot-only builds, or a fixture without core
  sources): the arms need the compiled definitions to exist.
- Observable differences are those of every direct call: no callinfo frame for the callee (a
  backtrace omits it), and the entry's arity check is replaced by the compile-time one.
- `scripts/bc2cpp_block_core_direct_check.rb` checks the generated arms and every reason they
  are withheld, then compiles a closed-world fixture together with the compiled core, links it
  into a full-core mruby and requires the same output as the interpreted build for results,
  `break`/`next`/`return`, exceptions, Fibers, `Enumerator#next`, GC pressure, subclasses,
  singleton receivers and user `each` objects.
- Residual risk: an engine block that stores a value only in a captured local of the enclosing
  compiled frame is unrooted while the callee runs (pre-existing; the same slot is unrooted on
  the dynamic path).

## Update (ADR 0283)

An arm whose literal block is proved yield-free, calling a body that cannot suspend a Fiber on its own,
omits `M->c == M->root_c`; the other arms keep it. The build prints how many arms did (`== yield-free
proof (YIELD_REACH) ==`).
