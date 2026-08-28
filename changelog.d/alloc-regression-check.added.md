- **A standing regression guard for the RPG2000 map scene's per-frame mruby
  object churn.** The `RGSS::Profiler.stats[:object_types]` investigation
  behind PRs #1436, #1438, #1447 and this one cut the map scene's per-frame
  Array/Proc/env allocation by well over half across several rounds, each
  found and measured by hand with a temporary instrumentation pass reverted
  before commit — none of it was guarded against silently regressing. Two
  new pieces close that gap:
  - The profiler's Chrome trace export now mirrors a `mruby_type_allocs`
    counter series alongside the existing `mruby_types` (live counts, which
    rise and fall with GC): the same per-type breakdown as **cumulative**,
    never-reset allocation counts, straight off `RGSS::Profiler`'s own
    counters (`mruby-gc-type-live-counts.patch`) — no new cost, the numbers
    were already computed for the live breakdown. Diffing two samples' values
    by their timestamps gives a real per-second (or per-frame) allocation
    *rate*, which the live-count series alone cannot answer.
  - `scripts/rpg2k_alloc_regression_check.rb` automates the exact manual
    measurement this whole investigation used: boots the engine on Nepheshel,
    samples that new series at two points in a steady window, and fails if
    the measured Array/Proc/env rate exceeds a ceiling set from this scene's
    own measured baseline (docs/profiling.md's new "Per-frame object
    allocation" section) — checked to actually catch reverting this round's
    fixes (`env` trips first, then `Proc`, well before `Array`). Wired into
    CI alongside the other RPG2000 boot smokes (display 122).

  Verified: `ctest` (all 8 targets, including the real compiled binary with
  the new trace field), the new script itself in both `--report` and
  asserting mode (against the current tree, against `Array#include?`'s fix
  alone reverted, and against this whole round's fixes reverted), and the
  rest of the RPG2000 ruby-checks trio — all pass unchanged.
