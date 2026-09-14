# 0153: bc2cpp `&:sym` per-element devirtualization (MONO direct + POLY guard chains)

## Status

Accepted.

## Context

ADR 0152 inlines `&:sym` block-pass sites (`ary.reject(&:dead?)`) as a
native loop around one `mrb_funcall` per element -- a hash-table method
lookup per element, even when the target is statically known. A
whole-program census of the 27 real `&:sym` sites shows most targets are
devirtualizable:

- MONO + clean: `out_of_play?` (11 sites), `gauge_full?`, `moving?` --
  exactly one bytecode definition program-wide, already compiling clean.
- POLY, all defs clean: `dead?` (3 defs), `hidden` (2 defs).
- Unavailable: `defending`/`even?`/`succ`/`upcase` (native-only, no
  `_impl` exists), `dispose` (16 defs) / `update` (21 defs) / `map(&:name)`
  (8 defs) over any reasonable chain cap, `full_heal` (MONO but itself
  block-blocked, excluded by the cleanliness gate).

No element-type analysis is needed for MONO (one def program-wide means
dispatch can only ever reach it). POLY needs a per-element class decision
-- but NOT a static element-type proof: a runtime exact-class guard per
candidate with an `mrb_funcall` fallback is always sound, because unlike
a literal block (which `mrb_funcall` cannot carry -- ADR 0147's core
rejection), a symbol-call carries no closure, so the fallback IS exact
`Symbol#to_proc` semantics. The TYPED path's trace-then-guard machinery
is inapplicable (a loop element is a synthesized `mrb_ary_ref`,
untraceable by backward scan), hence guards instead of traces.

## Decision

`sym_call_target(sym)` (next to `monomorphic_target`) applies
`compile_send`'s full MONO guard sequence -- pure-mandatory arity,
arity-0 match (a `&:sym` call passes no positionals by construction),
`compiles_clean?`, ONLY_OWNERS/OTHER_OWNERS emission gate -- returning
`[:mono, def]`, `[:poly, defs]` (2-4 defs, ALL passing, cap 4
user-confirmed), or nil. A partial pass is all-or-nothing: a skipped def
is a real dispatch target, so anything less than every def falls back to
plain `mrb_funcall` (an optimization miss, never a misroute).

`emit_sym_inline` emits, per site: MONO -- direct `_impl` call, no guard;
POLY -- statement-level if/else-if/else over exact-class `==` checks
(`const_chain_value_expr`, verbatim TYPED shape) with `mrb_funcall`
fallback; otherwise today's unconditional `mrb_funcall`, byte-identical.
Two helpers (`sym_call_value` declaring the result local,
`sym_call_line` for `each`'s discard case) because C `if` is a statement,
not an expression -- caught by g++ building the first real chain, not
assumed. No recognizer, `compile_insn`, or arg-gate changes.

Side finding (documented, no behavior change): keyword-argument calls
park LOADSYM'd key symbols in neighbor registers too, but are always
plain SEND/SSEND -- the opcode (SENDB/SSENDB-only recognizer), not the
slot, disambiguates. The 14 CALL_KEYWORD resolutions this round's regen
shows versus the each-inline baseline are an artifact of diffing against
a tree that predates PR #1681's keyword-call support, not new
compilations by this round: master-vs-branch emission for
`apply_pending_item`'s `:command_item n=2|nk=5` site is byte-identical.

## Verification

- Runtime harness (fresh `libmruby_core` + core gems + numeric-ext):
  MONO direct (`[Imp.new].map(&:power)` -> `[7]`), POLY chain hitting all
  4 branches (`[10, 20, 30, 40]`), fallback to a singleton-method foreign
  element (`[10, 99]`), over-cap 5-def and native-only sites confirmed
  byte-identical `mrb_funcall`, empty-map edge. All pass (5 + over-cap probes).
- End-to-end regen all three gems (same in-process harness as ADR 0152,
  validated against known counts): rpg2k 1678 -> 1688 clean (+10, the ten
  keyword-blocked methods whose callees were already compiling -- their
  CALL_KEYWORD blockers resolve through the unchanged keyword path, now
  unmasked in the diff), zero newly-skipped on any gem; every other
  category byte-identical. No `register.cxx`/`owners` changes (capability
  only, wiring = separate PR).
- `g++ -fsyntax-only` clean on probe output against real headers
  (plus two real g++-caught fixes during development: `if`-as-expression
  and a missing result-local declaration).

## Consequences

- Per-element dispatch cost at devirtualized `&:sym` sites drops from a
  hash lookup to (MONO) nothing or (POLY) up to 4 class comparisons.
  Megamorphic sites (`dispose`, `update`) intentionally stay dynamic.
- Callee-side work (`full_heal`'s own blocks) remains the blocker for
  `each(&:full_heal)` -- orthogonal future round.
- Element-type static inference (proving `@ui[:foes]` holds Combatants to
  drop even the guard) is deferred: the guards already capture the
  dispatch saving with zero analysis, and inference would recurse through
  `map`-literal support not yet built.
