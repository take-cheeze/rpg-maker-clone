# 0151: bc2cpp keyword call-site compilation (devirtualized into compiled callees)

## Status

Accepted.

## Context

`compile_send` has always rejected any call site with keyword arguments
(`n=2|nk=1`) via its honest `#error` path — originally for a real,
live-correctness reason (docs/adr/0139's follow-up documents six
already-shipped methods silently dropping keywords before the fix).
Since then, CALLEE-side keyword support landed (docs/adr/0149): compiled
`_impl` functions take each keyword as an explicit `(value, given)` pair.
But callers passing keywords still never compiled — 27 methods blocked
ONLY by this shape, plus the keyword half of ~19 mixed-shape methods.

## Decision

New `compile_keyword_send` path in `compile_send`
(tools/bc2cpp/bc2cpp.rb): for a `SEND`/`SSEND` with `nk>0` (no splat),
verify every keyword key comes from a `LOADSYM` literal (backward scan,
same spirit as `trace_new_target`), resolve the callee via MONO-only
lookup, and emit a direct `_impl` call with missing keywords as
`mrb_nil_value()` + `given=0` (exactly the entry wrapper's own
`mrb_undef_p` semantics for omitted keywords).

Two deliberate bounds (both user-confirmed):

- MONO-only, no TYPED path: a traced-receiver guard's `else` branch
  would need a dynamic keyword dispatch, which `mrb_funcall*` cannot
  express (`ci->nk = 0`, 3rd/mruby/src/vm.c) — any guard failure would
  silently drop keywords. MONO needs no guard (exactly one def exists),
  so it is unconditionally sound. POLY keeps the `#error`.
- Literal-symbol keys only: a computed key has no static name for the
  callee's keyword table. Splat (`n=*`), unknown arity, native callee,
  or a required keyword missing at the call site all keep the `#error`.

Required-keyword safety: a call missing a callee-required keyword is
rejected (nil), since the interpreter raises ArgumentError there —
compiling it would be silently wrong (the same class of bug the
original `#error` existed to prevent).

## Verification

- `SKIP_UNSUPPORTED=0` regen: 10 newly-clean methods
  (`RPG2k#fire_preview_animation`, 3 `Scene::Battle`, `DebugMenu#play_animation`,
  5 `Scene::Map`), zero lost entries (1651 → 1661 clean, nothing removed).
- The other 17 keyword-blocked methods correctly stay interpreted: their
  CALLEES don't compile (optional+keyword mix, BLOCK bodies, `n=*`
  splat) — callee-side work, not call-site work.
- All three gems' `register.cxx` updated (10 new entries, symbols
  verified against regen output); `arm-none-eabi-g++ -fsyntax-only`
  clean pending (same check as prior rounds).
- CRuby suites + strip verification pending (same discipline as prior
  rounds).

## Consequences

- Keyword call sites to MONO compiled callees now devirtualize; the
  remaining keyword gap is callee-side (mixed optional+keyword defs,
  BLOCK-using callees) and splat sites — each a separate future round.
- `SSEND` now threads `irep`/`idx` into `compile_send` (previously
  dropped); verified safe — both existing uses are `!self_implicit`-
  guarded, so positional-SSEND codegen is byte-identical.
