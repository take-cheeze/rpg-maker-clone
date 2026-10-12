# 0410. Enable parallel prerequisites in bc2cpp test builds

Date: 2026-10-12

## Status

Accepted

## Context

The bc2cpp test builders requested `rake -jN`, but mruby uses ordinary tasks
for its build products. Rake's worker limit does not turn ordinary tasks into
multitasks. A cold shared full-core build reported `Total threads in play:
0 + main`, even with 16 requested workers. This makes each cold test-library
build serial despite the job setting.

## Decision

Pass `-m` in all ten bc2cpp test mruby build invocations, alongside `-jN`.
This matches the main host build's existing multitask scheduling. Preserve
the existing 16-worker ceiling and apply it to the two formerly uncapped
width/native-slot builders as well, since enabling parallel execution on a
large local machine otherwise launches one worker per CPU.

The distinction between `-j` and `-m` is documented in
[Rake's command-line manual](https://ruby.github.io/rake/doc/command_line_usage_rdoc.html).

## Consequences

A local x86_64 Linux clean full-core build, with compiler caching disabled
and identical source/configuration, took 36.05 seconds with `-j16` alone
and 12.61 seconds with `-m -j16`. The latter reported 15 worker threads plus
the main thread. This measures a cold build and does not imply the same gain
on a restored artifact. The two builds used separate empty output directories.

Parallel compilation raises aggregate compiler memory use; the worker ceiling
bounds it. Rake's prerequisite edges still enforce generation-before-compilation,
and build errors, produced-library checks and runtime assertions are unchanged.
