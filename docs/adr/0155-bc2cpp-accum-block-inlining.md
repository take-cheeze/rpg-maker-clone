# 0155: bc2cpp accumulator-block inlining (`any?`/`all?`/`none?`/`count`/`reduce`/`inject`)

## Status

Accepted.

## Context

After ADR 0154 (collection blocks), the remaining literal-block census
is: `any?` (34 sites), `reduce`/`inject` with init (16), `count` (3),
`none?`/`all?` (1 each) -- 55 sites, all the same `BLOCK R(a+1)` +
`SENDB/SSENDB` adjacency (confirmed against real `mrbc -v` for every
name). Shapes: predicates take 1-mandatory-arg blocks (`n=0`);
`reduce`/`inject` take 2-mandatory-arg blocks with exactly one
positional init (`n=1`, registers dest/init/block -- `BLOCK R5` +
`SENDB R3 :reduce n=1`, confirmed). No-init `reduce` (`n=0`, first
element seeds) stays out -- its empty-array (nil) and single-pass
nuances need their own emitter, a follow-up.

## Decision

`recognize_accum_regions` (same adjacency + Array gate + arity match as
every recognizer above; fold sites verify the BLOCK at dest+2 with init
at dest+1) feeds `emit_accum_inline`, which clones the collect loop:

- Predicates: boolean destination with early exit (any?: false default /
  first-truthy-true; all?: true / first-falsy-false; none?: true /
  first-truthy-false). `break v` overrides via the same broke-flag
  pattern as collect (confirmed against CRuby: `any? { break 99 }` is
  99). Empty-array defaults fall out with zero iterations (confirmed:
  any?->false, all?/none?->true).
- `count`: fixnum tally, no early exit; `break v` overrides (confirmed:
  `count { break 7 }` is 7).
- `reduce`/`inject(init)`: accumulator seeded ONCE from the SENDB's own
  R(dest+1) before looping (never per-iteration); each iteration binds
  param 1 to the accumulator, param 2 to the element, and feeds the
  yielded value back. The init register is copied before the loop, so a
  body writing the same enclosing register later cannot affect
  iteration -- sound by copy timing.
- Live `RARRAY_LEN` + `mrb_array_p` raise-guard, identical to every
  emitter above. Bodies translate via `compile_collect_body_insn`
  (yielded-value capture shared with collect -- no new body translator).

Wired through the existing suppressed-address/glue-at mechanism; zero
changes to `compile_insn`, arg gates, or earlier emitters.

## Verification

- Runtime harness (fresh `libmruby_core` + core gems): any?/all?/none?
  hit+miss, count, reduce/inject with init, all four empty-array
  defaults, break-with-value in any?/count/reduce, `next`-with-value in
  any?, outer-local capture in reduce. All 18 pass.
- End-to-end regen all three gems (same in-process harness, validated
  against known counts): rpg2k 1713 -> 1718 clean (+5:
  `Battle#do_nothing_restricted?`/`#incapacitated?`,
  `Troop#apply_appear_randomly`,
  `Scene::Map#animation_target_resolves?`/`#events_dirty?`), lcf/rgss
  unchanged; zero newly-skipped on any gem. `OP_BLOCK` 339 -> 333,
  `OP_SENDB` 316 -> 310; every other category byte-identical.
- Most remaining `any?`/`reduce` sites stay interpreted for their own
  separate reasons, confirmed per-site: opaque incoming-array receivers
  (`alive?(side)`, `avg_agi(side)` -- method parameters no trace can
  see), not shape gaps. The gate working as designed.
- `g++ -fsyntax-only` clean on probe output against real headers.
- No `register.cxx`/`owners` changes (capability only, wiring =
  separate coverage PR per the established split).

## Consequences

- No-init `reduce`/`inject`, callee-side `yield`/`&blk`, `sort`-family,
  and `BREAK`-in-`times` stay interpreted. The broke-flag + yielded-
  value-capture patterns now cover every Enumerable shape except
  comparators and no-init folds.
- Remaining literal-block work is mostly receiver-side (opaque incoming
  arrays need call-site element/argument-type pooling along ArgTypes'
  lines), not shape-side -- the recognizers admit every real shape seen.
