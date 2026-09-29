# 0158: bc2cpp include/prepend ancestor scan — re-derive `super` soundness

Date: 2026-09-19

## Status

Accepted.

## Context

`bc2cpp` compiles a bare/parenthesized `super`/`super(...)` only for entries in
the hand-vetted `SUPER_TARGETS` allowlist (and the separate `n=*`
`ZSUPER_NATIVE_*` path). That allowlist exists because a `super` is only sound
to devirtualize into a *specific* superclass `_impl` when two whole-program
facts hold, and `compile_insn` cannot see either from one opcode (SUPER_SUPPORT,
`tools/bc2cpp/bc2cpp.rb`):

1. no real caller ever passes a block into the `super`-calling method, and
2. **no `include`d module sits between the class and its declared superclass.**

Fact 2 was pure hand-assertion. Worse, `build_registry` models the ancestor
chain through `@superclass_of`, which is populated **only** from `OP_CLASS`
(`class X < Y`) — bc2cpp has no `include`/`prepend` model at all. So the fact
that makes `super` resolution correct was not just asserted, it was
un-derivable. This blocks any general (non-allowlist) `super`/`super`-zsuper
support: the optcarrot scoping probe (`tools/optcarrot_probe`) has seven APU
zsuper sites that are otherwise clean and could compile, but cannot be accepted
without first being able to *prove* the ancestor chain is clean.

## Decision

**Add a whole-world `include`/`prepend` scan to `build_registry`
(`ANCESTOR_MIXINS_SUPPORT`).** A class/module body's `include M` / `prepend M`
is a self-implicit `SSEND R(self) :include n=1` immediately preceded by a
`GETCONST`/`GETMCNST` of the module constant (confirmed against real `mrbc -v`
of both this project's two `include Enumerable`s and optcarrot's two `include
CodeOptimizationHelper`). `build_registry` already walks every class/module body
for `private`/`attr_*`/`module_function`; the same arm now records:

- `included_modules` / `prepended_modules` (owner -> modules), and
- `unknown_mixins` — an owner whose `include`/`prepend` this walk sees but
  cannot fully resolve (explicit receiver, >1 argument, or an unresolvable
  module constant). These tables thread out of `build_registry` into `CodeGen`.

The scan resolves unqualified mixin constants only after all declared class and
module paths are known, following lexical nesting from the current namespace
toward the root. It accepts the relation only when the first declared path is a
module; ambiguous or non-module paths remain in `unknown_mixins`. Closed-world
typed dispatch can then follow the actual lookup order (prepends, owner,
included modules newest first, superclass), including transitive module mixes.
Every traversed module must have stable constant identity, and the first method
definition must be unique, public, and compiled. The receiver still gets an
exact runtime class guard and a dynamic fallback. `super` keeps its stricter
presence-only gate because a module can intercept the superclass call.

**Gate `super` on a re-derived guard `CodeGen#super_reaches_superclass?`**
instead of a hand-written fact: it declines when the owner has an unrecognized
mixin (`@unknown_mixins`) or carries **any** plain `include` (`@included_modules`),
and trivially reaches when it has none. `super_target` now calls it. The `super`
guard does not consult `prepend`: a prepended module sits *above* the class in
the ancestor chain, so it cannot come between a method and its own `super`.

**The `super` guard remains presence-only, not name-matching.** Even with a
resolved mixin relation, a `super` call must account for the complete ancestor
chain and where lookup resumes; the method-target lookup above does not prove
that fact. Declining whenever any plain `include` is present is the safe rule
for `super` and matches this file's standing "no wrong guess, ever" bar.
Prepend is used by ordinary method lookup but cannot sit between a method and
its superclass for this `super` proof.

## Consequences

- `super` soundness no longer rests on a hand-written "no intervening include"
  claim: it is re-derived every run, so a future `include` added to a
  `SUPER_TARGETS` class is caught automatically (the `super` declines).
- Real-project output is unchanged (proven: `scripts/bc2cpp_coverage_check.bash`
  regenerates `docs/bc2cpp_coverage.txt` byte-identically), because none of the
  compiled `super` owners has a plain `include`.
- General `super`/zsuper compilation for classes that include modules remains
  unsupported. The method-target lookup described above is not enough to prove
  where a `super` call resumes in the full ancestor chain.
- Covered by `scripts/bc2cpp_include_ancestor_check.rb` (drives real
  `build_registry` resolution and `CodeGen` ancestor dispatch over synthetic
  closed worlds), wired into the build job alongside coverage freshness.
