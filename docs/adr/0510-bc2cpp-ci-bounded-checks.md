# 0510. Bound concurrent bc2cpp CI checks and use a dedicated host shell

Date: 2026-10-20

## Status

Accepted

## Context

Master CI run 39315767499 spent 52 seconds restoring the default Nix store,
30 seconds generating base RBS, another 26 seconds regenerating it for the
base-section comparison, and several minutes running independent checks in
sequence. The job needs host compiler tools rather than the default shell's
Wine, Emscripten, graphics and game dependencies.

## Decision

Use `devShells.bc2cpp`, with a separate Nix cache namespace. Let the environment
export helper accept a flake installable, retaining `.` as its default.
The base-section comparison keeps its freshly generated RBS as the job's base
RBS output; the output directory must be absent or empty to reject stale files.

Prepare the full-core fixture library once, before running checks. Export its
location through `BC2CPP_MRUBY_FULL` so concurrent fixtures only read it. Include
the pinned toolchain, both contributing submodules and mruby patches in its
exact cache key. Run all existing checks through the existing timed-check
wrapper with two workers, retaining complete per-command logs, failure status
and timing summaries. Keep closed-world compilation and archive verification
before the checks.

## Consequences

The job restores fewer dependencies, performs base generation once, and overlaps
independent analysis work without duplicating the job's checkout or environment.
Two workers limit memory pressure from simultaneous Ruby analyses; native base
RBS generation retains its existing two-worker limit. Timings under concurrency
include contention and should be compared using whole-job elapsed time too.
The first run uses cold caches for the new environment and fixture cache keys.
