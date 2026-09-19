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

**Gate `super` on a re-derived guard `CodeGen#super_reaches_superclass?`**
instead of a hand-written fact: it declines when the owner has an unrecognized
mixin (`@unknown_mixins`) or carries **any** plain `include` (`@included_modules`),
and trivially reaches when it has none. `super_target` now calls it. `prepend` is
recorded but never consulted: a prepended module sits *above* the class in the
ancestor chain, so it can never come between a method and its own `super`.

**The guard is deliberately presence-only, not name-matching.** Resolving the
included module to the exact owner path `build_registry` gives its methods is
the general Ruby constant-lookup problem this file already approximates
(class-relative resolution inside a class body mis-names a top-level `include M`),
and a *wrong* match is the unsound direction. Declining whenever any plain
`include` is present is the safe direction and matches this file's standing
"no wrong guess, ever" bar; a class with no plain includes (every current
`SUPER_TARGETS` entry, every optcarrot zsuper site) reaches unchanged.

## Consequences

- `super` soundness no longer rests on a hand-written "no intervening include"
  claim: it is re-derived every run, so a future `include` added to a
  `SUPER_TARGETS` class is caught automatically (the `super` declines).
- Real-project output is unchanged (proven: `scripts/bc2cpp_coverage_check.bash`
  regenerates `docs/bc2cpp_coverage.txt` byte-identically), because none of the
  compiled `super` owners has a plain `include`.
- This is the **prerequisite**, not the `super` feature itself: general
  `super`/zsuper compilation for classes that do `include` a module needs a
  follow-up that first fixes the class-body constant-scope naming so the guard
  can safely tell "includes a module that defines the `super`d name" from "does
  not" — until then those classes decline.
- Covered by `scripts/bc2cpp_include_ancestor_check.rb` (drives the real
  `build_registry` + `CodeGen` guard over a synthetic closed world), wired into
  the build job alongside the coverage-freshness step.
