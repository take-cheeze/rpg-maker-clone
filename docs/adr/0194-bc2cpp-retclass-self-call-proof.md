# 194. RETCLASS_SELF_CALL_SUPPORT: class hints through a self-called MONO method

Date: 2026-09-22

## Status

Accepted

## Context

`ClassLayout.analyze`'s whole-program `trace_new_target` walk proves an ivar
always holds an instance of one specific class -- a `CLASS_HINT` -- without
needing to embed it, enabling direct-call devirtualization on that ivar's
value. Auditing the ~512 ivars still poisoned to `OPAQUE` in the real
whole-program diagnostic found `trace_new_target`'s own `case insn.op` had an
arm for `SEND0`/`SEND` (explicit-receiver calls: `.new`, `.dup`, chained
accessors) but **no arm at all for `SSEND0`/`SSEND`** (a bare, implicit-
receiver self-call, `foo(...)`) -- any such call fell straight through to the
generic `else: return nil`. Confirmed via real disassembly this is not a
hypothetical shape: `@background = build_field_background(@skin)` and
`@actor_window = new_window(0, 0, ...)` (both real, `mruby-rpg2k/mrblib`
sites) compile to exactly `SSEND`, not `SEND`.

`ARRAY_RETURN_PROOF` (`compute_array_return_names`) already proves an
analogous whole-program fact for one fixed target -- "every real return path
of this MONO method holds an Array" -- and is already threaded into
`ClassLayout.analyze`'s own SETIV loop as a chained-evidence source
(`array_ret_proof`), through a documented two-level stratification that
breaks the real mutual-dependency cycle between the two analyses ("`@queue`
is an Array because `turn_order` returns one, and `turn_order` returns an
Array because `@queue` is one" has no base case if resolved naively at a
single level). The identical cycle exists for an arbitrary class, and the
identical fix applies.

## Decision

Added `compute_class_return_names`, the object-reference analogue of
`compute_array_return_names`: same MONO admission rule (exactly one real
definition anywhere in the closed world, none in the foreign mrblib set
either -- no other receiver could ever reach a different body, so which
subclass's `self` happens to make the call is irrelevant), same
`array_return_analyzable?`/`straightline_return_reg?` guards reused verbatim
(the "does this body's own instruction list really contain every return
path, with no catch handler/nonlocal exit/join hiding one" question is
type-independent). Unlike `ARRAY_RETURN_PROOF`'s fixed target, different
candidates here prove different classes, and one candidate's own proof can
depend on another's (a self-call chain) -- so instead of `ARRAY_RETURN_
PROOF`'s shrink-from-assumed-true fixpoint (only sound for a single, fixed
binary target), this one **grows from empty**, admitting a name only once
every one of its own real return sites independently traces to the SAME
class, the same "prove upward from evidence" shape `ClassLayout.analyze`'s
own outer sweep already uses. Always terminates: the set only ever grows,
bounded by the finite candidate count.

Threaded through exactly like `array_ret_proof`: a new `ret_class_proof:`
parameter on `trace_new_target` and `ClassLayout.analyze`, a new `when
'SSEND0', 'SSEND'` arm (self-calls can never join the `.new`-chain/chained-
accessor logic the explicit-receiver arm handles -- a bare `new(...)` with
no receiver would dispatch to an instance method literally named `new` if
one exists, never `Class#new`), and the identical two-level stratification
in the driver (a `class_layout_probe` level-0 table, `compute_class_return_
names` computed against it as a level-1 fact, fed into the real, final
`ClassLayout.analyze` call as `ret_class_proof`).

## A real bug this round caught, not just a design question

The new `SSEND0`/`SSEND` arm's last statement was originally a bare trailing
expression, `ret_class_proof.call(name)`, not `return ret_class_proof.call
(name)`. Every genuinely terminal arm in this `case` needs an explicit
`return` -- the `case` sits inside the `(idx - 1).downto(0) do |i| ... end`
loop's own block, so a bare expression only produces that ONE iteration's
block value; the backward walk simply continued past it toward `ENTER`,
silently discarding a correct answer. Caught empirically, not by inspection:
a stub `ret_class_proof` correctly extracted the right method name and would
have returned the right class, but the real end-to-end result was still
`nil` -- traced by instrumenting the loop directly and watching it walk
straight past a successful resolution. Fixed by adding the explicit `return`,
matching every other terminal arm in this same function.

## What was verified

- Confirmed real per-bucket findings before choosing this fix: of ~512
  `OPAQUE` ivars, 222 are already independently proven scalar by
  `IvarLayout`'s own (separate) analysis -- a diagnostic-accuracy gap, not a
  resolvability one, left alone here. Of the remaining ~290, roughly half
  have at least one self-call SETIV site -- the real, common gap this round
  closes a first slice of.
- A real whole-closed-world before/after regenerate-and-diff: **CLASS_HINT
  263 -> 268** (5 real ivars newly resolved: `RPG2k::Scene::StatusMenu`'s
  `@actor_window`/`@gold_window`/`@gauge_window`/`@param_window`/
  `@equip_window`, all resolving to `Window` through the shared, MONO
  `new_window` helper). `ELEM_HINT`/`HASH_ELEM_HINT` counts unchanged. Zero
  new `#error` markers; POLY dynamic-dispatch count unchanged (3370) --
  these 5 ivars are not yet consumed by a POLY-named call site anywhere in
  the compiled program, so this round's win is a real, sound analysis
  improvement without a currently-measurable codegen effect, same honest
  framing as `docs/adr/0191`/`0192`.
- Several real candidates the initial investigation named as "confirmed
  closeable" (`build_field_background`'s 5 `@background` sites,
  `build_list_arrow_sprite`'s chain) turned out NOT to resolve, and were
  verified NOT to be a bug: `build_field_background`'s own body has an
  unrelated `if skin ... else ... end` ternary (for a *different* local,
  `colour`) whose branch-merge address sits, in program order, between the
  `Sprite.new` producing the return value and the `RETURN` itself.
  `straightline_return_reg?`'s own guard -- deliberately conservative by
  design, refusing to walk backward through ANY jump target regardless of
  whether it touches the traced register -- correctly refuses this site.
  Confirmed directly by disassembly and by calling `straightline_return_reg?`
  in isolation. `build_arrow_sprite` (the other named candidate) is
  genuinely POLY (4 owner definitions) at the call site itself, even though
  two of its four definitions individually delegate to a shared MONO helper
  -- correctly refused by the same admission rule `ARRAY_RETURN_PROOF`
  already trusts elsewhere (a POLY name's call site can reach any of its
  real definitions; whole-program agreement, not per-definition inspection,
  is what this trust model requires).
- All 22 `scripts/bc2cpp_*_check.rb` static checks pass.
- A full, real `RPGMAKER_BC2CPP=1` desktop build compiles and links clean;
  `--rgss_effect_probe` reports `ok` and a `--rpg2k_new_game` boot reaches
  the map scene.

## Consequences

A real, if modest, class-hint resolution improvement (5 ivars today), with
the machinery now in place for the same mechanism to close more as new
self-called MONO factory methods are recognized as candidates -- and an
honest accounting of why the investigation's own optimistic hand-count (up
to 18 ivars) did not all survive contact with the real, deliberately
conservative guards this file already trusts elsewhere. Two real classes of
follow-up remain, deliberately not attempted here: (1) `straightline_return_
reg?`'s blanket "no jump target anywhere in between" rule is stricter than
necessary for a join whose branches don't touch the traced register at all
-- loosening it precisely would recover `build_field_background`'s own 5
`@background` sites and others like it, but needs its own careful,
separately-verified soundness argument; (2) extending admission to a POLY
name where every one of its real definitions independently proves the same
return class (not just a MONO name) would recover `build_arrow_sprite`'s own
8 ivars, but is a strictly harder, riskier proof than this round's MONO-only
rule and deserves its own investigation rather than being folded in here.
