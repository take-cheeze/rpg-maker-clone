# 0156: bc2cpp sort-family block inlining (`sort_by`/`uniq` via Schwartzian transform)

## Status

Accepted.

## Context

After ADR 0154/0155 (collection + accumulator blocks), the remaining
literal-block census is: `sort_by` (6 sites), `sort` (2),
`uniq` (2) -- 10 sites blocking `Game::Battle#ready_combatants`/
`#turn_order`, `Game::Transition#compute_block_order`,
`RPG2k::Scene::Map#draw_events`, `Game::TextReveal#initialize`, and both
`finish_round_animation`s. All emit the same `BLOCK R(a+1)` +
`SENDB Ra :name n=0` adjacency (confirmed against real `mrbc -v`).

Two strategies, split by what the block MEANS:

- `sort { |a, b| cmp }` (comparator): NOT compiled. A comparator runs
  O(n log n) times inside the VM's own native sort, driven by C code
  this file cannot reproduce -- there is no loop to inline. Recognized-
  and-rejected deliberately (honest `#error`), so a future round
  (comparator-as-retained-Proc, or `<=>`-key extraction) has a named
  place to extend.
- `sort_by { |x| key }` / `uniq { |x| key }` (key extraction): the
  Schwartzian transform in ordinary compiled operations -- extract keys
  through the inlined block body (yielded-value capture shared with
  collect: same `next`-collects-nil, same `break`-overrides with
  broke-flag), decorate `[key, index, elem]`, insertion-sort on
  `(key, index)` via public `mrb_cmp` (mruby.h: fixnum/float/string
  fast paths, `<=>` dispatch, -2 raises -- exactly native `sort_cmp`'s
  contract), undecorate. `uniq` dedups adjacent equal keys after the
  stable sort (first occurrence kept).

Correctness notes (each verified, not assumed):

- Stability: mruby's own sort is NOT stable, but CRuby `sort_by` IS
  (oracle: equal keys keep order) -- and game code depends on it
  (turn-order ties). Index decoration + explicit index tiebreak make
  stability structural, independent of algorithm choice.
- New arrays always: `sort_by`/`uniq` return fresh arrays (oracle);
  the receiver is only ever READ (`mrb_ary_ref`). Bang variants
  (`sort_by!`/`uniq!`) stay out -- in-place mutation needs aliasing
  analysis, a follow-up.
- Chained receivers (`reject(...).select(...).sort_by`): a new
  `chained_array_call` fallback rule -- when the static Array trace
  misses, one backward step accepts a receiver just written by
  `select`/`reject`/`map` (any dispatch shape), which return fresh
  Arrays unconditionally. Sound by SKIP_UNSUPPORTED's per-method
  partitioning: a gapped producer drops the whole method to the
  interpreter, so the rule only fires where every link proved.
- Mutation-during-key-block: key loop is live-length (same rule as
  every emitter); the sort phase iterates the KEY array's own length
  (1:1 with visited elements by construction). A mutating body is
  VM-undefined anyway (native sort raises "array modified during
  sort"), so any sane behavior there is acceptable.
- `max`/`min`/`max_by`/`min_by` stay out (same loop-with-key shape as
  `find` -- trivial follow-up, not this round).

## Verification

- Runtime harness (fresh `libmruby_core` + core gems): sort_by
  identity/size/negated keys, uniq literal, STABLE ties (the semantic
  that decoration exists for), `next`-without-value, break-with-value,
  outer-local capture (with reordering keys, so the test actually
  exercises the sort). All 8 pass.
- End-to-end regen all three gems: rpg2k 1713 -> 1713 (+0), lcf/rgss
  unchanged, zero newly-skipped anywhere. The 10 real sites stay
  interpreted for their own separate reasons, confirmed per-site: the
  key-block BODIES call uncompiled methods (`side_of` is itself
  BLOCK/SENDB-blocked; turn_order's key block chains unproven calls),
  and chained receivers bottom out at unproven roots (`SSEND0
  :all_combatants`, `GETIV @enemies`) -- the gate working as designed,
  not a shape gap. The chained-receiver rule fires nowhere today but
  is covered by the harness-shaped probe (chained `select.sort_by`
  with proven root compiles in isolation).
- `g++ -fsyntax-only` clean on probe output against real headers.
- No `register.cxx`/`owners` changes (capability only, wiring =
  separate coverage PR per the established split).

## Consequences

- This round adds +0 methods: it builds the sort capability and proves
  it correct, but every real site is blocked one level deeper (key
  bodies calling uncompiled methods, unproven chain roots). Unlocking
  them is receiver-side and callee-side work (unblocking `side_of`,
  proving `all_combatants`/`@enemies` element provenance), not further
  shape work -- the recognizers admit every real shape seen.
- Comparator `sort` blocks, bang variants, and `max`/`min`-family stay
  interpreted. The Schwartzian machinery (decorate/sort/undecorate
  with `mrb_cmp`) is available to any future key-extraction need.
- Insertion sort is O(n^2) worst-case, tuned for the tiny game arrays
  observed (turn order, event lists, transition bands); correctness is
  size-independent via the explicit index tiebreak.
