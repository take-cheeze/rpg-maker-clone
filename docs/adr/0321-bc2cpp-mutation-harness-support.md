# 0321. bc2cpp mutation harness support: control, world probe, crash-versus-assertion verdicts

Date: 2026-10-03

## Status

Accepted

## Context

The bc2cpp mutation checks break one soundness condition of the generator at a time and expect a named assertion of
the matching check to fail. Audited, they could report a kill that proved nothing:

- Four harnesses (`call_results`, `class_pools`, `tuple_return`, `loop_installers`) and the `BR_MUTANTS` and
  `GIA_MUTANTS` sections copied the generator to `/tmp`. bc2cpp.rb finds the engine's sources from its own location
  (`../..`), so the closed world there is a different, smaller one (41 native + 14 Ruby outside sources against 114 +
  24) and a mutant can die because no proof can be made. An earlier fix moved some harnesses inside the repository
  but nothing prevented the next copy from repeating it.
- Five harnesses linked the repository into a temp tree: the same entries, but different paths from the ones the check
  hands the tool, so a world that lists a core source both as compiled input and as outside source differs (the
  `BR_MUTANTS` control failed in such a tree).
- A kill was "the check exited nonzero" (`CSEND_MUTANTS`, `UCC_MUTANTS`, `GIA_MUTANTS`, `BR_MUTANTS`,
  `CX_MUTANTS`: any `FAIL` line) or "a FAIL line matched the label" with no way to tell the assertion from a crash
  next to it: a fixture build that no longer compiles, a binary that segfaults, a generator that raises.
- Seven harnesses had no unmutated control, and a control could pass while printing `SKIP`.
- A compiled-versus-interpreted leg could pass with the compiled VM never dispatching into compiled code (a fixture
  class left out of the owner list, a registration that matched nothing): both sections were the same bytecode.

## Decision

`scripts/bc2cpp_mutation_support.rb` is the single implementation every harness uses:

- `with_tree` places the mutant at `<repo>/.mutant*/bc2cpp` so its own `../..` is the repository (a `scripts` tree for
  checks that load the tool by relative path), and refuses any other layout (`LayoutError`).
- `run_harness` runs an unmutated control through the same tree beside the mutants. The control must pass, print at
  least five `ok` lines, not skip its run half, read the same closed world as the real tool (the `== closed world`
  counts of a one-class fixture against `bc2cpp_closed_world_outside_srcs`), and, when a mutant needs the run half,
  have dispatched into compiled code.
- `classify` returns `KILLED_BY_ASSERTION`, `KILLED_BY_CRASH` (timeout, no `FAIL` line, or the label next to a fixture
  build or binary failure the control does not have), `KILLED_ELSEWHERE` or `SURVIVED`. Only the first counts; a crash
  kill counts when the mutant declares `crash_ok`, with the reason in a comment. Every mutant needs the label of its
  assertion. The child never inherits a `*_MUTANTS`, `*_GENERATED_ONLY` or `*_TOOL` variable of the caller.
- Fixture runs write evidence to `BC2CPP_PROBE_LOG`. `Bc2cppFixtureRuntime.run` registers each compiled entry through a
  counting thunk and raises `VacuousCompiledLeg` when a compiled VM finishes without dispatching into any; gem-built
  and hand-written drivers use `PROBE_PROLOGUE` for the same. Fixture classes that `only_owners` leaves out are
  logged as `unlisted-classes`.
- `scripts/bc2cpp_mutation_harness_check.rb` runs deliberately broken harnesses (an empty world, a mutant that only
  breaks the C++ build, a control that skipped its run half) and must see them refused.

## Consequences

- A mutation check's green line now says that each mutant died of the assertion named for it, in the world the real
  tool reads, with a control that ran what it claims.
- Two `computed_send` mutants and two `class_pools` mutants are accepted crash kills: the missing gate makes the
  generator raise on nil, or the miscompiled code segfaults on a nil receiver, so no wrong code is ever produced or
  there is no assertion to name. They are findings, not silent passes.
- The control adds one run per harness (run in the pool beside the mutants, so the critical path grows by at most one
  mutant run; per-shard numbers in `docs/ci.md`).
- A driver built without `PROBE_PROLOGUE` still has no runtime probe; the audit in the pull request lists them.
