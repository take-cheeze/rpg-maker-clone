# 0184. Cache exact-class guard pointers in generated bc2cpp code

Date: 2026-09-21

## Status

Accepted

## Context

Every TYPED devirtualized call, POLY_SMALL_N chain and typed element guard
compares `mrb_obj_class(M, recv)` with the owner's class. That class was
resolved by a chained `mrb_const_get(..., mrb_intern_cstr(...))` expression
inside the guard, so each guard interned one string and did one constant
lookup per path segment (for example `LCF::Array1D` twice) on every call.
`const_chain_value_expr` documented the re-lookup as an accepted tradeoff.

## Decision

Emit one file-scope helper per owner, `bc2cpp_owner_class_N(M)`, and use it in
the guards. The helper stores the resolved `RClass*` in a static slot the
first time the lookup succeeds:

- The cache is keyed on the `mrb_state*`; a different state flushes it. The
  project already assumes one live VM at a time (`g_direct_construct_*`), so
  this is a safety net rather than a supported mode.
- `bc2cpp_reset_owner_classes()` is called from each compiled gem's
  `gem_final`, so a VM opened later at a reused address never sees a pointer
  from a closed one.
- A failed lookup (constant not defined yet) still raises from the same
  `mrb_const_get` and stores nothing.

## Consequences

Guards cost one compare and a static load after the first call. A constant
reassigned after the first guard is no longer noticed by the cached guards;
this matches the existing `g_direct_construct_*` globals, and RPG2k game
scripts do not reassign the compiled owner classes. The cached pointer is not
a GC root, which is safe for the same reason (the constant keeps the class
alive) and would only matter under reassignment. Runtime effect is unmeasured.
