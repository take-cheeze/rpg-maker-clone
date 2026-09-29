# 252. bc2cpp guards definer classes a chain cannot list, so the fallback is an error

Date: 2026-09-29

## Status

Accepted

## Context

ADR 0210's `ClosedWorld#refusal` turns a guard chain's `else` arm into
`bc2cpp_nomethod` only when every class that answers the name is guarded
(`required_classes(name) ⊆ listed`). A definer whose definition is not a
direct-call candidate (arity, an unclean body, a mixin in the way of
INHERITED_GUARD) was left out of the chain, so the arm kept a dynamic send for
"any other class" with the reason `unlisted_class`: 948 sites in the shipped
build, all of them in guarded chains (IVAR_ACCESSOR, MONO_EMBED_GUARD,
POLY_SMALL_N, TYPED). The catch-all send can only ever raise `NoMethodError`
for a class that answers nothing, but nothing proved that to the emitter.

## Decision

`guarded_fallback_line` handles the case where `unlisted_class` is the only
refusal. Each definer class the chain omits (or a descendant that inherits the
definition) gets its own exact-class branch that dispatches
(`mrb_obj_class(recv) == C`), and the refusal is re-evaluated with those
classes listed, so the remaining `else` becomes `bc2cpp_nomethod`.
`ClosedWorld#unlisted_classes` computes the set. It applies only when

- `unlisted_class` is the sole refusal, and the receiver is method_missing-free;
- every omitted class is a declared class (`class_declared?`, never a module)
  and a stable class constant, and there are at most
  `UNLISTED_CLASS_GUARDS_MAX` (8) of them.

A HOT_ONLY build (ADR 0214) never adds these guards: definers it leaves
uncompiled would look unlisted only there, and the resulting dead fallback could
not be in `NOMETHOD_REVIEWED`, which is the full build's list.

Anything else keeps the previous dispatch and reason. A class the compiler
cannot name, a module definer, `core_or_native`, `opaque_definer` and
`singleton_definer` are untouched.

## Consequences

- All 948 `unlisted_class` sites now end in `bc2cpp_nomethod`: dead fallbacks go
  from 3,065 to 4,013, and 716 new keys join `NOMETHOD_REVIEWED` (ADR 0226).
- Behaviour is unchanged: for a class outside the definer set the old send also
  ended in `NoMethodError` (no method_missing, no dynamic install, no core or
  native definer, all checked by `refusal`); only the route differs. The
  fixture in `bc2cpp_closed_world_check.rb` runs the generated code against the
  real mruby core and compares the raised error.
- The 716 keys were added by `bc2cpp_nomethod_reviewed_update.rb --write`
  after reading a random sample of 22 against their Ruby source (ordinary calls
  on `@state`, `@shop`, `self`, or behind `respond_to?`); the rest rely on the
  argument above, not on a per-key read. ADR 0226's review remains the place to
  re-check them if a receiver class ever turns out to answer nothing.
- Each omitted class costs one class comparison on the cold path.
