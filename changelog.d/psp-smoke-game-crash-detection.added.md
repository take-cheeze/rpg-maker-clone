- **`psp-smoke-game` now flags an emulator crash instead of silently
  swallowing it.** The first CI run to reach `Scene::Map` (via the new
  `.psp_ci_new_game` marker) surfaced a real `ppsspp-headless` segfault
  partway through the run -- but the job still reported success, since
  only the marker-presence assertions gated it and `|| true` on the
  emulator invocation absorbed the crash along with the ordinary case of
  a clean `--timeout`. The invocation now checks its own exit status: a
  signal-killed exit (128+signal, e.g. 139 for `SIGSEGV`) prints a
  `::warning::` annotation naming the signal, while a plain nonzero exit
  from a clean timeout (expected, not a crash) stays silent. Job pass/fail
  is unchanged -- this only makes a real crash visible in the job's own
  log instead of requiring someone to notice by reading raw output. See
  `docs/adr/0047-psp-memory-budget.md`'s P1c for the numbers.
