# 0295. bc2cpp: integer range proof and argument-class pooling, re-measured and not adopted

Date: 2026-10-01

## Status

Accepted (a decision not to build; revisit if a trigger below fires)

## Context

Two prototypes were shelved before the recent exactness work landed:

- **Integer ranges** (`origin/claude/integer-ranges-arrays-k4h`, ADR 0286 on that branch,
  about 4,500 lines: `int_range.rb`, `range_flow.rb`, `array_cells.rb`, `codegen_range_*.rb`). An
  interval per register/ivar, plus Array element cells, to drop the overflow tier of `+ - *`, to
  turn compares into native fixnum compares and to skip the negative-index wrap of `a[i]`.
- **Argument-class pooling** (`origin/claude/arg-class-pooling-t2x`, ADR 0282 on that branch). The
  class every call site passes for a parameter, used to dispatch on a parameter receiver.

Since then master gained the overflow-exact fixnum tier (ADR 0279), the per-loop step guard
(ADR 0287), typed numeric slow-path helpers (ADR 0292), the return-class table (ADR 0289), exact
receiver arms (ADR 0280) and the LCF row flow (ADR 0294). The question was what each prototype
still buys on top of that.

## Method

Each prototype was ported onto `origin/master` `f70fef67` in a scratch tree (the range one by merging
the branch and resolving the five conflicts, with the range emitters also wrapped around the
"operand proven Fixnum" arms that master now emits through `fixnum_exact_tier`; the pooling one by
applying its patch and re-hooking `codegen_send.rb` after `exact_flow_user_class`). Both ran
against the wio closed world (`wio_gen`-style `bc2cpp.rb` runs of the four compiled gems, as
`scripts/wio_bc2cpp_measure.bash` builds them) and against optcarrot through
`tools/optcarrot_probe/compiled_run.rb 180`. The ported range analysis reports its own census with
`BC2CPP_RANGE_COVERAGE=1`. Numbers are generated-C++ bytes and site counts from the generator;
no ARM link was produced, so flash/RAM deltas are not measured.

## Results

**Integer ranges, whole-program census (wio closed world).** 2,531 arithmetic sites: 634 have
exactly-Integer operands, 325 a proven bound (290 fit every target, 35 only where the target's
fixnum range is wider). 1,627 compares: 124 Integer-exact, 27 bounded. 3,701 index sites: 442
provably non-negative, 20 reads of a tracked Array element. Most "bounded" sites are
constant-by-constant arithmetic (`8 * 2`, `320 - 16`) or constant indexes.

**Integer ranges, what changes in the emitted code.**

| output (wio) | overflow-tier sites | range arms emitted | C++ bytes |
| --- | --- | --- | --- |
| `mruby-rpg2k-compiled` | 243 to 211 | 32 `+ - *`, 3 `==`, 16 `[]` non-negative, 1 `Array.new` | 2,655,744 to 2,646,156 (-0.36%) |
| `mruby-lcf-compiled` | 2 to 2 | 3 | 141,570 to 142,791 |
| `mruby-rgss-compiled` | 3 to 3 | 1 | 100,904 to 101,942 |
| `mruby-core-compiled` | 0 to 0 | 0 | 50,012 to 50,012 |

About 56 sites in total, below the 100-site bar, and the two small gems grow because the range
helpers and `static_assert` are emitted once per output. In-bounds Array proofs (candidate 2) are
the 20 tracked reads of the census, and the prototype only uses non-negativity (it skips the
`n < 0` wrap, it never drops the out-of-range-to-nil path), so no `a[i]` becomes a bare slot read.
The step-loop guard (candidate 3) covers one loop in the whole game (ADR 0287 counted it).

**optcarrot.** The probe is not a closed world (`BC2CPP_CLOSED_WORLD` refuses it), so the numeric
class proof the range analysis needs as input hardly fires: 463 arithmetic sites, 6 exactly
Integer, 1 bounded; 234 compares, 0; 319 index sites, 109 provably non-negative. The range tree
emits 1 arithmetic arm and 93 non-negative index reads, 308 changed output lines. Two alternating
rounds of the 180-frame benchmark on each tree (same checksum 59662 every time):

| tree | run 1 | run 2 |
| --- | --- | --- |
| master | 20.04 s | 21.13 s |
| ranges | 19.74 s | 21.03 s |

The 1.5% and 0.5% differences are inside the 5% spread between rounds of the same binary.

**Argument-class pooling.** The pool admits 104 exact and 149 hint facts, of which 11 exact facts
name an engine class (the rest are Integer, Float, Array, Hash, String, whose receivers stay
guarded because `closed_world_exact_target` refuses builtins). Effect on the `mruby-rpg2k-compiled`
output: zero unguarded `CLOSED_WORLD_EXACT_CLASS ... pooled entry argument` sites; one guarded site
changes (an `Array#include?` receiver gains a direct `TYPED` call), `bc2cpp_send(` 932 to 930,
`mrb_funcall` 994 to 995, 132 bytes smaller. The receivers it was written for (126 sites, 88 of
them engine code) are now typed by the return-class table, the LCF row flow and exact `Klass.new`
tracking.

## Decision

Neither prototype is ported. Master's exact tiers already take the dispatch and boxing wins; the
residual population each prototype reaches is tens of sites, and the range analysis would add a
4,500-line domain whose soundness (widening at loop heads, 31-bit and 62-bit fixnum bounds per
target, Array escape rules) has to be argued and maintained for about 50 sites and no
measurable optcarrot speedup. The two branches stay available as references.

## Triggers to revisit

- A schema oracle for LCF record fields (`rec[:hp]` in `[0, 9999]`) would feed the range domain the
  values most of the engine's arithmetic works on; the 2,531 - 634 non-Integer-exact arithmetic
  sites are where a range proof could pay, not the 325 it can already bound.
- A closed-world optcarrot configuration, or another target whose hot loop is Integer-exact and
  masked (`& 0xff`, `>> 8`), would change the optcarrot census above.
- Pooling becomes relevant if `closed_world_exact_target` ever admits builtin receivers.

## Consequences

No generated-code change. The numbers above are the baseline a future range or pooling proposal
should beat.
