# 0310. The block arms of ADR 0270 reach nested and re-counted sends, and a proven arm keeps no dynamic else

Date: 2026-10-02

## Status

Accepted

## Context

ADR 0270 gives a literal-block send an arm per exact core class (`Array_each_impl`, `Hash_each_impl`, ...) in
front of its `mrb_funcall_with_block`. At master `247a34e4` the wio closed world has 476 literal-block sends
(`scripts/bc2cpp_coverage_report.rb`): 370 direct, 77
dynamic only, 29 `&expr`. For the engine proper (`Game::*`, `RPG2k::*`, which is 356 of them) that is 277
direct, 68 dynamic only and 11 `&expr`. A debug trace of why the 68 stayed dynamic (temporary, not
committed) sorted them by cause:

| rpg2k dynamic-only sends | Count | Cause |
| --- | ---: | --- |
| a block nested in an inlined loop body (`2.times { rows.each { } }`) | 25 | `emit_block_fallback_glue` tries a direct call only when `inline_offset` is nil; the nested glue also had no owner definition |
| a proven or traced receiver whose arm chain was built twice | 5 | `direct_block_code?` demands `live _impl calls == direct_call_args calls`; the dropped build counted too |
| `Array.new(n) { }` | 10 | no compiled body: `Class#new` and C `initialize` |
| `RGSS::Profiler.section` 9, `File.open` 4 | 13 | native callees |
| `loop` 6, `reduce` 4, `index` 3, `each_line`/`each_char` 2 | 15 | no compiled core definition on the chain (`inject` uses `__send__`, `loop` is Kernel, `index` and the String iterators are C) |

The second row is not a property of the site. The same send is compiled more than once (the registered
expression, the tail of the POLY chain, `proven_miss_marker`), one build with the exact-receiver proof of ADR
0280 (one arm) and one without (three); both bump `@call_block_direct_calls` and only one text is kept, so the
count is 4 against 3 live calls and the send is thrown back to dynamic dispatch. Whether a site is direct then
depends on whether a dropped build happened to run first, which is also why the fixture reproducing it
(`@cells = table; @cells.each { }`) has `table` returning a literal.

The other half of the context is the arm that is already there. A proven class (ADR 0280) with a yield-free
block (ADR 0283) emits `if (true) { call } else { by-name send }`. The else is dead, but it is still a
`mrb_funcall_with_block` in the output: 31 in the wio build.

## Decision

All three parts are behind `BC2CPP_BLOCK_ARM_REACH=0`, which returns the earlier output byte for byte.

1. **Nested sends take the arms.** `compile_direct_block_send` accepts the register shift of a block inlined into
   a loop body. The synthetic send is `R<dest + offset>`; as for every other send in a shifted body it passes no
   `idx` and carries the unshifted site as `trace_idx`/`trace_reg_offset` (BLOCK_BODY_INDEX_SUPPORT), so the
   proofs that read the bytecode still read the right register. `inline_nested_block_pass` hands the glue the
   owning definition. Nested regions that break or return are still refused before this point
   (`inline_nested_region_has_break?`, `block_fallback_region_has_return_blk?`); nothing about the block, its
   env or its break/return tokens changes, only the call.
2. **The acceptance test counts by name.** `direct_call_args` also records its `impl` name. `direct_block_code?`
   keeps the old exact-total test and, failing it, accepts code whose every live `<owner>_impl(M` call is
   covered, by name and multiplicity, by a recorded call. A dropped build adds recorded calls that are not live;
   it can never make a live call that skipped `direct_call_args` look covered (a live name nobody recorded, or
   live more often than recorded, is refused). `mrb_funcall` and `#error` still refuse the code.
3. **A proven arm with a yield-free block is the call alone.** When the single remaining arm has no tests at all
   (class proven, no root-context test), the dynamic else cannot run and is not emitted. A guarded proven arm
   keeps its else for the Fiber case of ADR 0269, and an arm with a class test keeps it for every other
   receiver.

## Consequences

Measured on the wio closed world with `scripts/bc2cpp_coverage_report.rb`, shipped pass, before and after this
change on the same tree (host `mrbc` from a full-core mruby 4.0 build):

| | Before | After | Delta |
| --- | ---: | ---: | ---: |
| literal-block sends, direct call with the block (all owners) | 370 | 401 | +31 |
| literal-block sends, dynamic dispatch only (all owners) | 77 | 46 | -31 |
| `mrb_funcall_with_block` sites (all owners) | 448 | 407 | -41 |
| rpg2k (`Game::*`, `RPG2k::*`): direct | 277 | 307 | +30 |
| rpg2k: dynamic only | 68 | 38 | -30 |
| rpg2k: `mrb_funcall_with_block` sites | 328 | 287 | -41 |
| `bc2cpp_send` sites, `mrb_funcall` sites, `bc2cpp_slow_*` callers | unchanged | unchanged | 0 |

Removal versus relocation, honestly: 41 `mrb_funcall_with_block` sites are removed outright (31 of them were
already direct arms with a dead else; 10 are sends this change made direct and proven in the same step). The
other 20 sends that left "dynamic only" (nested 25 and re-counted 5, less the 10 above) keep a by-name else for
every receiver that is not exactly an `Array`, `Hash` or `Range` (or that runs under a Fiber), so they are a
relocation: the common receiver now calls the compiled core body directly, but the number of sites that can
reach by-name dispatch is not lower for them. 38 rpg2k and 8 other sends are still dynamic only, and the
`BLOCK_FALLBACK` marker count (447) is unchanged because every block body is still compiled as a cfunc.

- The arm for a nested send is emitted inside a loop that already runs in the method's frame, so it is exactly the
  call the top-level arm makes; the check compares compiled and interpreted output with nested sends over arrays,
  hashes, ranges, subclasses, singleton receivers, user `each` objects, frozen and mutated receivers, `next`,
  `raise`, GC calls inside the block, and Fibers whose `each` yields.
- The tolerance in (2) is a consistency check on the generator's own text, not a proof about the program. It does not
  weaken the soundness of an arm, which is decided where the arms are built.
- Not done, with the cost seen: `Array.new(n) { }` (10 rpg2k) needs an inlined loop for a constructor and a proof
  of the `Array` constant; the Profiler and `File.open` calls (13) are native callees taking a block; `loop`,
  `reduce`, `index` and the String iterators have no compiled body.

## Verification

`scripts/bc2cpp_block_arm_reach_check.rb` (its own `block-arm-reach` shard of `bc2cpp-checks`): generated code
for the nested, re-counted and proven cases with the kill switch as the control; every arm chain names one
receiver register in its tests, calls and else; worlds that withdraw the arms (open world, no core, a Ruby
`Array#each`/`Range#map`, a prepend, a dynamic installer); unit cases of `direct_block_code?`; the driver
compiled over the compiled core against the interpreter on a full-core, a core-only and a 32-bit `mrb_int`
mruby, each also under incremental-GC stress; and eight mutants of the soundness conditions
(`BR_MUTANTS=1`).
