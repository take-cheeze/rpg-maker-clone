# 0488. Native base RBS generation in bounded file workers

Date: 2026-10-18

## Status

Accepted

## Context

Native base RBS generation preprocesses each source and obtains its Clang JSON
AST to infer return kinds. A local whole-repository run took 36.4 seconds:
14.6 seconds capturing Clang AST output, 14.1 seconds parsing JSON, and 4.9
seconds scanning preprocessed native text. Ruby-source generation took 0.37
seconds. The largest individual process reached about 2.4 GiB RSS.

Each native file is analyzed independently, but `BaseRbsNative` stores its
current file's return kinds in `@ast_kinds`. Threading those scans would mix
file state. Clang's AST filter matches declaration-name substrings; selecting
registered methods alone would also omit same-file helpers used by return
analysis.

## Decision

`BaseRbsWorkers.map` forks a fresh child per native source, with at most two
children active by default, or one on a single-processor host. Each child
runs the existing AST analysis, preprocessing and scanner without changing
their inputs. It serializes only the scan result to a private temporary
directory and exits without running inherited exit hooks. The AST is never
returned to the parent.

The parent waits only for its own worker PIDs, starts pending work as slots
become available, and merges results and diagnostics in input order. Source
order still determines superclass replacement and skipped-registration
ordering. A child exception retains its class, message and backtrace. A child
that exits without a result, including a signal death, fails the scan.
Outstanding workers are reaped even if launching a later child fails.

Both generator CLIs accept `--jobs N` / `-j N`. `--jobs 1`, or a Ruby without
fork support, uses the original in-process serial path. Native results are
rendered and validated in the parent. Ruby generation and gem ordering remain
sequential; this avoids nested worker pools.

## Consequences

Independent Clang and Ruby JSON parsing work can use multiple CPUs, and a
completed file's AST memory is released with its child. Concurrency is capped
because multiple ASTs can require substantial aggregate memory; the maximum
RSS of one process does not measure the pool's total footprint. Larger job
counts are an explicit caller choice. No cache or new dependency is added.

`scripts/bc2cpp/base_rbs_check.rb` checks bounded concurrency, deterministic
results and diagnostics, worker exception/termination handling, child cleanup,
and serial/parallel RBS equivalence with real Clang and same-named helpers in
different source files. See [generation measurements](../bc2cpp-base-rbs.md).
