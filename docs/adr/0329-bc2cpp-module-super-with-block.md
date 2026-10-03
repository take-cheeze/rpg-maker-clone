# 0329. `super` through an included module, carrying the block

Date: 2026-10-03

## Status

Accepted

## Context

`bc2cpp_coverage_report.rb` reported 21 `#error` markers whole-program. Seven
were `unhandled opcode SUPER`, in five places:

| method | sites | its `super` reaches |
| --- | ---: | --- |
| `Range#max` | 2 | `Enumerable#max` |
| `Range#min` | 2 | `Enumerable#min` |
| `Range#to_a` | 1 | `Enumerable#entries` (via `alias to_a entries`) |
| `File#initialize` | 2 | native `IO#initialize` |

`Range` includes `Enumerable`, and `mruby-range-ext` redefines `#max`/`#min`
with `super`. ADR 0146 added `SUPER_TARGETS` for the common case, resolving the
target as "the same-named method on the declared superclass", and
`super_reaches_superclass?` **declines whenever the owner has any plain
`include`**. That is not caution — it is required. Measured against mruby
(`scripts/bc2cpp_super_ancestry_check.rb`): a class that includes a module
resolves `super` *into* that module, and `Sub.ancestors` is
`[Sub, Mid, Base, Object, ...]` with `Sub#pick` answering `Mid`, not `Base`. A
lookup that walked to the superclass would call the wrong method. The same check
pins that two includes are searched **newest-first** (the later `include` wins),
that a **prepended** module sits above the class and so wins the super outright,
and that OP_SUPER forwards the caller's block to the module body reading it.

## Decision

Resolve the super target over mruby's real search order — `[class, included
modules newest-first, superclass, ...]` — and emit a direct `_impl` call
carrying **this frame's block**.

Three facts make the direct call sound where `SUPER_TARGETS` is not:

1. **The block is forwarded, not dropped.** OP_SUPER always forwards the
   current method's block. A compiled `_impl` has no block to invent, which is
   why `SUPER_TARGETS` needs its "no caller ever passes a block" allowlist
   entry by entry. Here the block is real: `super_block_arg` returns the
   `bc2cpp_blk` slot whenever the frame has one (`&block` or a yield-only
   frame) and `module_super_call` appends it when the target's `_impl` takes
   it. This is not optional. `(1..5).max { |a,b| -b }` is **1** in mruby, not
   5; a super that passed nil would silently return 5 for every block caller.
2. **The target is looked up in both registries.** The engine gems' `@registry`
   and mruby's own compiled core (`block_core_index`, which also resolves the
   `to_a`/`entries` alias) are separate: `Enumerable` never appears in
   `@registry` at codegen time, so a lookup consulting only it finds nothing.
   Two live definitions of one name on one owner decline rather than guess.
3. **A CORE_BLOCK_GUARD body is reachable only when proved yield-free.**
   `compiles_clean?` refuses every guarded body (ADR 0269), which is right for
   the existing direct-call sites: the guard is the only thing standing between
   a `Fiber.yield` inside a block and a compiled frame it cannot cross. That
   guard lives in the method's *entry wrapper*, not the body — and a `super`
   reaching the body is already inside a compiled frame on the same context.
   `module_super_body_usable?` therefore allows a guarded body only when
   `core_body_relaxable?` holds, which is the build's own yield-reach proof
   that the body and every nested block never yields. That is exactly what the
   guard's `M->c != M->root_c` arm tests at run time
   (`bc2cpp_block_yield_free`), so a body passing it is not one whose Fiber
   safety depended on the guard. The guard's other arm,
   `!bc2cpp_core_each_is_builtin(M, self)`, is a receiver-side runtime fact
   this path does not touch: it fires only when the target is statically the
   module's own method on the receiver's own class.

Unchanged: `File#initialize`'s `super(fd, mode)` reaches a **native**
`IO#initialize` whose body calls `mrb_get_args`, so it needs a call frame and
cannot be a direct-call target. That is ADR 0315's standing finding, not a gap
in this one. A zsuper (`ARGARY` + `SUPER n=*`, a bare `super` in a method with
parameters) keeps its `#error`: it is a different shape, already handled by
`zsuper_forward_plan` where that applies.

`BC2CPP_MODULE_SUPER=0` restores the previous `#error` at these sites.

## Consequences

Unhandled-SUPER markers go 7 to 2, and the whole-program total from 21 to 16.
`Range#max`/`#min`/`#to_a` now compile, so they stop being dropped wholesale by
`SKIP_UNSUPPORTED=1`; the remaining two are `File#initialize`.

The five marker sites were the whole of the win. BLOCK (4), SENDB (2),
SSENDB (2) — `Array#permutation`, `Enumerable#cycle`,
`File.singleton#foreach` — EXCEPT (2) — `IO.singleton#open` — the three
`reachable from a Fiber.new block` markers (`LCF::Array2D#each`,
`Game::Actors#each`, `Game::Party#each`) and `IO.singleton#popen`'s
non-mandatory arguments are untouched and still measured.

`scripts/bc2cpp_module_super_check.rb` runs the shape end to end: the kill
switch, module-vs-superclass order, block forwarding (`first=3` vs `negate=1`,
the pair a dropped block would collapse), a nil block, and the negative worlds
— a zsuper, two live definitions of the name, a module without the name, and a
frame with no block slot facing a target that needs one. Seventeen checks, with
compiled-vs-interpreted parity across two VMs.
`scripts/bc2cpp_super_ancestry_check.rb` pins the ancestor order this decision
rests on, so a future mruby that searched differently would fail a check rather
than silently mis-resolve.
`scripts/bc2cpp_module_super_range_check.rb` measures the real `Range` on the
whole-program pass: the five markers return with the kill switch off, and the
emitted call carries `bc2cpp_blk`. It runs the full three-gem compile twice, so
like `bc2cpp_coverage_report.rb` it is an on-demand measurement rather than a
line in the CI shards.

Not run here: the 32-bit `mrb_int` leg, firmware smokes, the optcarrot
open-world comparison.
