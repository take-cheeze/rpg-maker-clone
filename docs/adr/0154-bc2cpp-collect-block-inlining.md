# 0154: bc2cpp collection-block inlining (`map`/`select`/`reject`/`find`/`each_with_index`)

## Status

Accepted.

## Context

After ADR 0152 (`each` literal + `&:sym`), a fresh closed-world census
found 162 literal collection-block sites still on the interpreter: `map`
(70), `each_with_index` (71), `select` (21), `find` (21), `reject`
literal (8) -- plus `any?` (38), `reduce` (16), `count` (3), which stay
out (each needs accumulator/early-exit codegen of its own, a follow-up).
All five in-scope methods emit the identical `BLOCK R(a+1)` +
`SENDB/SSENDB Ra :name n=0` adjacency as `each` (confirmed against real
`mrbc -v` for every name, never assumed) -- only the block arity differs
(1 for map/select/reject/find, 2 for each_with_index, confirmed via the
child irep's own ENTER: `1:0:...` vs `2:0:...`).

## Decision

`recognize_collect_regions` (same adjacency + same static Array gate as
the each recognizer, including the SSENDB/owner rule) admits only
arity-matching shapes (1-arg map/select/reject/find, 2-arg
each_with_index -- a mismatch is a real ArgumentError on the
interpreter, so it keeps the honest `#error` rather than compiling a
silently-wrong loop). `emit_collect_inline` clones the each loop with
four measured differences:

- Yielded-value capture: the block's own return forms (`RETURN` with
  value, `RETNIL`/`RETFALSE`/`RETTRUE` -- a real `next`, possibly
  valued) store into a per-iteration result local before jumping to
  iter-end (new `compile_collect_body_insn`; everything else delegates
  to `compile_block_body_insn` unchanged). Value-less `next` stores nil
  -- real `map { next if c }` collects nil (confirmed against CRuby).
- Result slot per method: `map` pushes each result into a fresh Array;
  `select`/`reject` push the element on truthy/falsy; `find` takes the
  first truthy-result element (nil default, early exit);
  `each_with_index` binds param 2 to the loop index and discards like
  `each` (destination keeps the receiver).
- `BREAK Rv` assigns the SENDB destination (L_UNWINDING value semantics
  -- `map { break 99 }` is 99, confirmed against CRuby) guarded by a
  dedicated broke-flag boolean: without it the post-loop accumulator
  assignment overwrites the break value with a partial accumulator (the
  exact `[1, 2]`-instead-of-`99` bug the runtime harness caught). A
  loop-index comparison was considered and rejected (pop-during-
  iteration can shrink length below a break index). `find`'s own
  truthy-match exit shares the break label but assigns the found slot,
  not dest, so it needs no flag interaction.
- Live `RARRAY_LEN` loop + `mrb_array_p` raise-guard, identical to each
  (push-during-`map` visits new elements, confirmed against CRuby).

Wired through the existing suppressed-address/glue-at mechanism; zero
changes to `compile_insn`, arg gates, or the each/sym/times emitters.

## Verification

- Runtime harness (fresh `libmruby_core` + core gems): map literal,
  `next`-without-value collects nil, select/reject literal, find
  hit/miss, break-with-value (the harness-caught bug), each_with_index,
  non-local return in map (hit + fall-through collects), outer-local
  capture. All 11 pass.
- End-to-end regen all three gems (same in-process harness as ADR
  0152/0153, validated against known counts): rpg2k 1688 -> 1713 clean
  (+25), lcf 35 -> 37 (+2: `Array1D#to_lcf`, `Array2D#to_lcf`), rgss
  unchanged; zero newly-skipped on any gem. `OP_BLOCK` 367 -> 339,
  `OP_SENDB` 344 -> 316; every other category byte-identical.
- `g++ -fsyntax-only` clean on probe output against real headers.
- No `register.cxx`/`owners` changes (capability only, wiring =
  separate coverage PR per the established split).

## Consequences

- `any?`/`all?`/`none?`/`count`/`reduce` literal blocks, callee-side
  `yield`/`&blk`, `sort`-family, and `BREAK`-in-`times` stay interpreted
  -- the first group is the natural next round on this same machinery
  (accumulator + early-exit, reusing the broke-flag pattern).
- The broke-flag pattern (`mrb_bool`, set only on break, zero
  per-iteration cost) is available to any future emitter with a
  post-loop assignment.
