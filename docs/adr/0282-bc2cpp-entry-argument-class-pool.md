# 0282. bc2cpp: pool the class of a parameter over every call site, for receiver dispatch

Date: 2026-09-30

## Status

Accepted

## Context

The largest group of receivers bc2cpp cannot type, after send results, is an incoming argument
(`incoming_or_unwritten_register`, 126 sites in the wio closed world, 88 of them engine code).
`trace_new_target` named such a register only from a `# bc2cpp:` class annotation, because pooling
call sites is unsound for a name several classes define. ADR 0276 already pools argument *class
sets* for numeric operands over the sites `ENTRY_ARG_CALLSITE_PROOF` enumerates (one definition,
every outside source silent about the name, every site a visible positional call). This ADR
reuses that admission for receiver classes.

## Decision

`codegen_arg_class_pool.rb` computes, for each admitted (method, argument) pair, the class every
call site passes, in two tables. Each is a greatest fixpoint: hypotheses come from the sites that
prove, then any key with a site that fails under the current table is dropped until stable. This
admits recursion and pass-through chains.

- **exact**: each site is proven without a guard: a NumericFlow class set naming one class
  (Integer, Float, Array, Hash, String), a `Klass.new` that dominates the read
  (`exact_new_receiver_class`), or the caller's own exact parameter (`walk_dominating_writers`
  reaching the entry). A site passing only nil adds nilability, not a class. A receiver that is
  such a mandatory parameter, never nilable, dispatches through `closed_world_exact_target`
  with no guard and no fallback (`CLOSED_WORLD_EXACT_CLASS ... pooled entry argument`).
- **hint**: each site is traced as a guarded receiver would be (ClassLayout ivar hints count).
  `JoinDominance.guarded(entry_classes)` scopes the table and `at_entry` reads it, so a guarded
  consumer names the class and keeps its runtime check.

Admission beyond ADR 0276: optional positionals are allowed (a site passing fewer leaves the
default; the default's writer defeats the exact proof, and the guarded walk sees the default
first), rest/post/keyword parameters are refused, a block parameter is ignored. A site must be a
plain positional call (no `nk=`, no splat). Names a computed `send` could build are refused
(`numeric_dynamically_named?`). Methods of the RGSS API, the core classes, `Object` and
`Kernel` are refused (`CLASS_POOL_SCRIPT_ROOTS`): a game script the compiler never sees can call
them by name.

## Soundness

Induction over the calls of one run: the first call to a method comes from a site that proves
without the hypothesis; every later call passes what an earlier call received. Site
enumeration is `entry_arg_call_index`'s argument (send/method/define_method are absent from the
closed world or poison via LOADSYM; native and foreign sources poison by token; `super` needs a
second definition, so the name is not single). Hint-tier facts are performance only (the guard
stays). Assumption for the exact tier: a user script does not call engine-internal classes
(`RPG2k`, `Game`, `LCF`) by constant with a wrong-class argument.

A pre-existing hole is closed: `alias new old` poisoned only `new`, so calls through the alias
reached `old`'s body unseen by ENTRY_ARG_CALLSITE_PROOF and NUMERIC_ENTRY_ARG_PROOF; the second
token now poisons too.

## Consequences

- Builtin receivers (Array etc.) keep their guard: `closed_world_exact_target` refuses builtins
  whose names a native could define. Only engine-class receivers lose the guard.
- `initialize` arguments (constructor calls) and element-typed arguments (`cmd[:x]`) are out of
  scope.
- Checked by `scripts/bc2cpp_arg_class_pool_check.rb` (positive, negative, compiled vs
  interpreted). Measured results are in the branch report.
