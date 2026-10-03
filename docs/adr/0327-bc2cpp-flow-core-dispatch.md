# 0327. Resolve flow-proven core calls before user-class polymorphic chains

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0325 measured six RPG2k and two LCF `Hash#delete` calls whose receivers
are proven exact by class flow but whose generated calls still dispatch by
name. The exact receiver already reaches `exact_core_site`; the remaining
gap is emission order. `compile_poly_small_n` can return a user-class chain
with a dynamic `core_or_native` else before the final CORE_EXACT_DIRECT wrapper
gets to resolve the core receiver.

## Decision

Try the existing blockless `core_exact_direct_line` with the site's exact
receiver proof before building a polymorphic chain. Keep its existing target
lookup, visibility, arity, compilation, override, installer, singleton-freedom,
and Fiber suspension checks. Only a successful compiled-core lookup returns
here; all other sites continue through the existing chain construction.

This is a call-order change, not an additional class inference or native
implementation of `delete`. `BC2CPP_CORE_EXTEND=0` disables it along with the
other CORE_EXACT_DIRECT calls.

## Consequences

The shipped wio census on `fdf8a884` with the same local mruby source inputs
before and after removes eight `bc2cpp_send` sites: six RPG2k and two LCF,
all `Hash#delete`. Body sends fall from 2,542 to 2,534 and CORE_EXACT_DIRECT
sites rise from 81 to 89. Helper-held sends stay at 24, block funcalls at 400,
body funcalls at 28, and NoMethodError sites at 4,380. No new helper relocates
these calls.

The existing core-exact check now covers pooled Hash deletion and fetch,
Hash-or-nil error behavior, class pools disabled, the core switch disabled,
and a Hash override. Its runtime driver compares deletion results and
subsequent receiver state against interpreted mruby, including absent keys.
