# 0330. A block forwarded out of an optional-arg or nested block body

Date: 2026-10-03

## Status

Accepted

## Context

After ADR 0329 the whole program's `#error` markers were 16, and 8 of them were
the same shape: `unhandled opcode BLOCK` / `SENDB` / `SSENDB`, in three methods.

| method | sites | shape |
| --- | ---: | --- |
| `Array#permutation` | 2 | `def permutation(n = size, &block)` |
| `Enumerable#cycle` | 2 | `def cycle(nv = nil, &block)` |
| `File.singleton#foreach` | 2 | `def self.foreach(file)`, no `&block`, `yield` in a nested block |

All three hand the method's own block to something inside a nested block, so
their BLOCK_FALLBACK body has to carry `bc2cpp_blk` into the cfunc. Two
independent gaps stopped that, and both are in how a block body is admitted
rather than in what it compiles to.

**The wrapper extracts a block the admission test does not know about.**
`frame_block_available?` answered `pure_mandatory_arity? || block_param_arity?`.
`block_param_arity?` requires `opt.zero?`, so `def permutation(n = size, &block)`
— an optional argument *and* a block — fails it, even though `compile_method`
reaches that shape through `optional_block_arg_table` (CORE_BLOCK_OPT), sets
`has_blk`, and extracts `bc2cpp_blk` in the wrapper all the same. The region was
then admitted with `blk_available` false, so `needs_blk` was false and the body
could not forward the block. `File.foreach` is the yield-only sibling: it
declares no `&block`, and `yields_block_param?` (which does cover it, via
`block_given_reads?`) was not consulted either.

**A nested body's `lv == 2` BLKPUSH names its parent REGION, not the method.**
`File.foreach`'s `yield l` sits in `f.each { ... }` inside
`self.open(file) { ... }`, and mruby emits `BLKPUSH R3 1:0:0:0 (2)`. vm.c
`OP_BLKPUSH` walks `uvenv(mrb, lv-1)`, so that resolves to the enclosing
region's block — which the parent already holds as its own `bc2cpp_blk`
parameter. The shipped code set `@blk_param_level = 1` for every body and passed
the *method's* `blk_available` into the nested recognize, so a level-2 body was
declined at admission and then `#error`ed on its own BLKPUSH. Its own comment
claimed "Deeper needs keep `#error` (none exist)"; `File.foreach` is that case.

## Decision

Two admissions, both re-deriving a fact the wrapper already establishes.

`frame_block_available?` also accepts `optional_block_arg_table(irep)` (the
CORE_BLOCK_OPT shape) and `yields_block_param?` (the yield-only shape). The
first is exactly the condition `compile_method` uses to set `has_blk`; the
second starts with `return false unless pure_mandatory_arity?`, so neither arm
can widen an optional/rest/keyword shape the wrapper does not already unwrap.

A region whose BLKPUSH level set is `[2]` (and not `[1]`) needs its parent's
block, so:

- `recognize_block_fallback_regions` admits `blk_needs == [2]` as well as `[1]`;
- the nested recognize passes the enclosing body's `needs_blk` as
  `blk_available`, not the method's;
- `@blk_param_level` becomes the body's own nesting depth instead of a constant
  1, set **before** the nested pass so a child can derive its level from it.

Nothing extra crosses the call boundary: the parent already has the block in
`bc2cpp_blk`, and `emit_rproc_construction` appends it to the child's env in
either case. A nested body whose levels are all 1 still reads the *method's*
block, which is why the level set is matched exactly rather than by "is not 1" —
`t_bg_in_blk2` and `t_bg_yield_in_blk2` in
`scripts/bc2cpp_proc_call_block_given_check.rb` are that case, and passing the
parent's block there answers a different question.

`BC2CPP_OPT_BLOCK_FRAME=0` restores the previous behaviour.

## Consequences

The block-family markers go 8 to 0 and the whole-program total from 16 to 8:
BLOCK 4, SENDB 2 and SSENDB 2 are all cleared, and `Array#permutation`,
`Enumerable#cycle` and `File.singleton#foreach` compile instead of being
dropped wholesale by `SKIP_UNSUPPORTED=1`.

This touched shared BLOCK_FALLBACK machinery, so the neighbouring checks are the
evidence: `bc2cpp_proc_call_block_given_check` (164 scenarios),
`bc2cpp_block_semantics_check`, `bc2cpp_block_arm_reach_check` and
`bc2cpp_rescue_inline_block_check` all pass. An earlier version of this change
did regress the first two — the nested block was given the parent's block
unconditionally, so `t_bg_in_blk2` answered `[true, true]` instead of
`[true, false]` — which is what the exact level-set match above exists to
prevent.

`scripts/bc2cpp_optional_block_frame_check.rb` covers both halves: the
optional-arg-and-block wrapper, the kill switch, and a `yield` two block levels
deep (`nest=[10, 20, 30]`, and a LocalJumpError-free return), with
compiled-vs-interpreted parity across two VMs.

Still 8: `EXCEPT` 2 (`IO.singleton#open`), `SUPER` 2 (`File#initialize`, whose
`super` reaches a native `IO#initialize` that needs a call frame),
Fiber-reachable 3, and `IO.singleton#popen`'s non-mandatory arguments. None of
them is this shape, and all stay measured.

Not run here: the 32-bit `mrb_int` leg, firmware smokes, optcarrot
open-world comparison.
