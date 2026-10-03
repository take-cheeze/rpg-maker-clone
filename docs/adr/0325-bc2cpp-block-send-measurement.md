# 0325. bc2cpp: what keeps the by-name dispatch of block sends, measured per site (nothing built)

Date: 2026-10-03

## Status

Accepted

## Context

After ADR 0270, 0271, 0283, 0310 and 0314 a literal-block send (`x.each { }`, `x.map { }`) calls the compiled core body
through an exact-class arm (`Array`, `Hash`, `Range`, `Integer`) and keeps the dynamic `mrb_funcall_with_block` as its
else unless the receiver class is proven. The request was to remove more of those by-name sends in the engine gems with
four levers, and to build the sound ones that remove at least 30 sends (the same cutoff ADR 0317 used):

* (a) SENDB support in `CodeGen#receiver_instances` / CALL_FACTS (ADR 0317): post-call receiver facts for block sends.
* (b) `Array.new(n) { }` as a direct compiled call.
* (c) a direct entry for blocks that `break` or `return` (ADR 0271 leaves them on the cfunc wrapper).
* (d) `Hash#delete` / `Array#delete` direct entries (21 engine `delete` sends, 6 with a proven Hash receiver).

Measured on master `7818f0f5` (wio closed world, `3rd/*` populated, host `mrbc` of mruby 4.0, shipped pass of
`scripts/bc2cpp_coverage_report.rb`; `bc2cpp_send` 2,513 and `mrb_funcall_with_block` 400 in the generated bodies, the
numbers moved from the 2,603 / 401 of `docs/bc2cpp-baseline-2026-10-02.md` by ADR 0320 and later commits). The new
report `BC2CPP_BLOCK_SEND_REPORT=<tsv>` (`tools/bc2cpp/block_send_report.rb`, aggregated by
`scripts/bc2cpp_block_send_report.rb`) writes one row per block send (the last compile of a site wins) and changes no
generated code (`shipped.cxx` of two runs, with and without other reports, is byte-identical; the check compares the
output with the report on and off). Scope below is by gem (`mruby-rpg2k`), not by function-name prefix, so it differs by
a few sites from the 277 of the baseline.

### Every block send of the engine gems

`mruby-rpg2k`: 352 block sends, 282 of which still reach a by-name line (70 do not: 42 are the compiled call alone,
28 resolve to one compiled call without a chain else). By shape of the generated glue:

| Shape | rpg2k | lcf | rgss | Meaning |
| --- | ---: | ---: | ---: | --- |
| `removed` (compiled call alone) | 42 | 0 | 0 | proven class, yield-free block, relaxable body |
| `exact_arms` (class tests, dynamic else) | 227 | 8 | 6 | the receiver class is not proven |
| `dynamic` (no compiled callee) | 38 | 3 | 3 | no core arm for the name |
| `mono_direct` (one resolved call) | 30 (2 keep a chain else) | 0 | 0 | |
| `explicit` (`&expr`, no body) | 12 | 0 | 0 | |
| `proven_guarded` (proven class, else kept) | 3 | 0 | 5 | the block has no direct entry |

The 282 by-name sites of rpg2k by callee: `each` 93, `each_with_index` 38, `map` 34, `any?` 18, `select` 18, `reject` 12,
`new` 10, `section` 9, `each_index` 8, `loop` 6, `find` 4, `open` 4, `reduce` 4, `sort_by` 4, `times` 4, `index` 3, then
one or two each.

Why the dynamic line is kept (rpg2k, 282 sites):

| Reason | Sites |
| --- | ---: |
| receiver class not proven (arms are class tests, the else answers every other receiver) | 227 |
| no compiled core callee (`new` 10, `Profiler.section` 9, `loop` 6, `File.open` 4, `reduce` 4, `index` 3, `each_char`, `each_line`) | 38 |
| `&expr` block | 12 |
| proven class, the block has no direct entry (`break`/`return`) | 3 |
| one resolved call whose chain else is kept | 2 |

The Fiber guard (ADR 0269) is not a reason any more: every literal block is proved yield-free (the engine world has no
Fiber seed, ADR 0314) and every arm body is relaxable (`Array+,Hash+,Range+` in the report), so 215 of the 227
`exact_arms` sites (the other 12 have no direct entry) would be the compiled call alone **if the receiver class were
proven**. The receiver is the whole problem:

| Receiver of the 282 by-name sites | Sites |
| --- | ---: |
| exact-class flow proves it | 4 (3 `Array`, 1 `Integer`) |
| earlier call on the value bounds a user-class set CALL_FACTS would accept | **0** |
| earlier call bounds a set with core/native members (`core`, `core+user`, `core+native+user`) | 21 |
| earlier call names nothing that bounds a class | 5 |
| no earlier call on the value | 252 |

Producer of the receiver register (nearest writer): call result 76, an Array literal merged with another value
(`(ids || []).each`) 49, `GETIDX` element 47, incoming argument 37, constant 20 (`Array.new` 10, module constants),
ivar 16, `loadnil` 10, `getmcnst` 9, self 6, arithmetic 6, Hash literal 4.

### The four levers, counted in the engine gems (rpg2k / lcf / rgss)

| Lever | rpg2k | lcf | rgss | Total | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| (a) CALL_FACTS for SENDB | 0 | 0 | 0 | **0** | no block send has a usable user-class set; 21 have core/native-bounded sets |
| (b) `Array.new(n) { }` | 10 | 1 | 0 | 11 | all 11 are `Array.new`; the receiver is a constant, unproven today |
| (c) direct entry for `break`/`return` blocks | 3 | 0 | 5 | 8 | of 23 / 1 / 8 blocks without an entry, only these 8 sit on a proven class (the others keep a class-test else) |
| (d) `delete` | 8 | 2 | 0 | 10 | proven receiver: Hash 6 + 2 (lcf), Array 2; 14 + 1 + 1 more `delete` sends have no proven class |
| Sum of the four | 21 | 3 | 5 | **29** | if every lever were built, sound, and independent |

Details that matter for risk:

* (a) CALL_FACTS accepts only declared user classes (ADR 0317). Block sends are `each`, `map`, `select`...: names that
  Array, Hash and Range answer, so a fact such as `x.size` or `x.empty?` bounds the receiver to core classes (4 sites with
  `Array|Hash`, and `Array|Hash|String`) or to a mixed set that contains user classes with their own `each` (17). A
  user-class `each` with a block is compiled only as one resolved call (POLY chains do not carry a block,
  `compile_poly_small_n` returns nil with a block), so no mixed set loses its else. The only widening that removes
  anything is a core-only set that the arms cover: 4 sites (`map` x2 with `{Array, Hash}`, `each_with_index` x2 with
  `{Array, Hash, String}`), and it needs an Array/Hash subclass and singleton freedom proof first.
* (b) The call is `Class#new` then C `Array#initialize`, which yields; there is no compiled body to call. A direct form is
  a new loop helper (size coercion, negative size `ArgumentError`, `break`, GC arena per yield) plus proofs that the
  `Array` constant is stable and nothing overrides `Array.new` or `Array#initialize`.
* (c) The direct entry reads the captured env from `env->stack`; a `break` or `return` token would have to move from the
  frame's callinfo into the env layout (ADR 0271 keeps the wrapper because of exactly this). The other 24 blocks
  without an entry (20 + 1 + 3) sit on unproven receivers and would keep their else.
* (d) `Hash#delete` is mruby Ruby (`mrblib/hash.rb`, `delete(key, &block)` over native `__delete`), so it is a compiled
  core body, and a literal `{1 => 2}.delete(k)` already becomes `Hash_delete_impl` (CORE_EXACT_DIRECT, ADR 0314). The
  8 proven-Hash engine sites (6 rpg2k, 2 lcf) keep `bc2cpp_funcall_explicit ... CLOSED_WORLD kept: core_or_native`
  because their receiver is proven by the class flow (ivar pools, ADR 0302), which CORE_EXACT_DIRECT does not read: it
  needs the literal/fresh-container proof of ADR 0280 (`exact_core_site`). The lever is to feed a flow-proven exact
  core class into that site, not a native entry. `Array#delete` is a C body (`mrb_ary_delete`) that calls `mrb_equal`
  per element (user `==`, GC arena restores, "array modified during delete") and has no compiled body (the target walk
  says `Array is not plain (native ...)`), so its 2 proven sites need an audited NativeCoreDirect entry for a long
  body; the audit's 11 entries are all a few lines.

## Decision

**Nothing is built.** The cutoff is at least 30 removed by-name sends in the engine gems. The four levers together reach
29 at their ceiling, only by building three unrelated mechanisms (an Array-constant loop helper, a break/return env
layout, reading the class flow in CORE_EXACT_DIRECT plus an audited `Array#delete` entry) and each of them alone is 11 or less (a 0, b 11, c 8,
d 10). A fifth, unlisted, widening (core-only fact sets, 4 sites) would take the sum to 33 and needs the subclass proof
of ADR 0317's next-lever list. Removal per unit of risk is poor everywhere; no PR slice is separable above the cutoff.

Shipped instead:

* `BC2CPP_BLOCK_SEND_REPORT=<tsv>`: one row per block send with the shape of its glue, the receiver proof
  (exact flow), the post-call facts (names, class kinds, whether CALL_FACTS would accept the set), the direct-entry and
  yield-free flags, the exact core arms and why a name has none, and the nearest producer of the receiver.
  `scripts/bc2cpp_block_send_report.rb bs.tsv [--gem GEM] [--list SHAPE|facts]` prints every table of this ADR.
* `scripts/bc2cpp_block_send_report_check.rb` (generated code only): the report changes no output, and the rows of a
  fixture with a proven receiver, an unproven one, `loop`, `Array.new`, `&expr`, a returning block and a receiver bounded
  by one fact are what they should be. It runs in the `call-facts` shard (about 15 seconds).
* The census section of `docs/bc2cpp-dynamic-site-census.md`.

## Consequences

* No generated code changes: there is no kill switch to measure and no removed-versus-relocated number to give.
* The lever worth building next is a receiver-class proof, not a block-send mechanism: 215 rpg2k sites become the
  compiled call alone when the receiver is proven (nothing else is needed: entry, yield-free and relaxable bodies all
  hold). The producers are call results 76, `x || []` merges 49, `GETIDX` elements 47, arguments 37: the same
  receiver-origin work as ADR 0309's ivar pools and the "foreign spelling" call results of the baseline.
* `Array.new(n) { }` is 11 sites for a helper plus two constant proofs; do it with the first lever that touches the
  `Array` constant, not alone.
* `Hash#delete` (6 + 2 sites) is CORE_EXACT_DIRECT reading the class flow, not a native entry; it is the cheapest of the
  four and still only 8 sends. The same gap is wider than `delete`: 172 engine sends with a flow-proven receiver set
  still have a by-name line (`Array` 43, `Hash` 10, `Range` 9, `Integer` 3, `String` 3, user classes the rest); 68 of them
  are core-only sets (`pack` 16, `inspect` 11, `delete` 10, `include?` 8, `cover?` 5), a follow-up measurement of its own.
* Not run: no feature was built, so no mutation check, no compiled-vs-interpreted run on full-core, core-only or 32-bit
  `mrb_int` builds, no GC stress or Fiber world exists for this change. `pre-commit` and the local checks are listed in the
  pull request.
