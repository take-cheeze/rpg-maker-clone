# 49. Ruby line coverage measured from the host-side checks

Date: 2026-08-15

## Status

Accepted

## Context

The project has a lot of tests — the mruby gem suites run by `mruby_test`, the
`scripts/*_check.rb` harnesses in the `ruby-checks` CI job, the native smoke
tests that boot the binary on real games — and no way to say what they leave
untouched. "Is this path tested?" has been answered by reading the checks.

The code that matters is Ruby. `mruby-*/mrblib` is ~39 000 lines (the LCF and
RGSS data layers, the RPG2000 logic and scenes, the MV/MZ core) against ~3 000
lines of C++ in `src/`, which is SDL/mruby/LVGL glue.

Measuring it has one obstacle: the shipped runtime is **mruby**, which has no
coverage support at all — no `Coverage` module, no profiler hook to build one
from. What makes the problem tractable is a property the project already relies
on: that Ruby is written in the mruby/CRuby common subset, and the check
harnesses `load` those very files under CRuby (`scripts/rpg2k_logic_check.rb`
and friends). Under CRuby the stdlib `Coverage` module applies.

Three shapes were considered:

1. **Instrument the harnesses under CRuby** — measures the real sources, needs
   no new dependency, but only sees what the CRuby-hosted checks reach.
2. **Add coverage to mruby** — would cover `mruby_test` and the native smokes
   as well, but means carrying a patched interpreter or writing a bytecode
   instrumentation gem. Far more machinery than the question deserves.
3. **gcov/lcov for `src/**.cxx`** — standard, but those files are 8% of the
   code, are reachable only through the display-bound smoke tests, and the
   report needs `gcovr`/`lcov`, which the flake does not ship.

## Decision

Take (1). `scripts/coverage_report.rb` runs the host-side checks with CRuby's
`Coverage` stdlib enabled and reports line coverage of `mruby-*/mrblib` per gem
and per file, writing `coverage/lcov.info` (standard interchange, feeds
`genhtml` and the coverage services) and `coverage/coverage.json`.

Coverage must be started before the sources are loaded, so
`scripts/coverage_hook.rb` is injected into each check process through
`RUBYOPT=-r<hook>` rather than required by the harnesses. The harnesses are not
touched, a harness that spawns `ruby` is measured too, and each process writes
its own result for the reporter to merge — which is also what lets the checks
keep running concurrently. Files no check loads are added at 0% from
`Coverage.line_stub`, so an untested file lowers the total instead of being
absent from it.

CI runs it in `ruby-checks` and publishes the numbers in the job summary and as
a `ruby-coverage` artifact. It is report-only; `--min-line-rate` exists for
turning it into a gate later, deliberately unused for now, because the first
useful thing a coverage number does is show where the tests are thin, not fail
builds while that is still being learned.

Native C++ coverage is left out (option 3), and `mruby_test`/native-smoke
coverage is left unmeasured (option 2).

## Consequences

- The gaps become visible and rankable: the report's per-file tail is a list of
  where the next host-side check pays off the most.
- The number is a **floor**, not a truth. `mruby_test` and the native smokes
  exercise the same sources inside mruby, invisibly to this. Files needing a
  live RGSS window or a JS engine (`mruby-rgss/mrblib/lib.rb`,
  `mruby-mvjs/mrblib/{mv,mz}.rb`) therefore read 0% while being covered by other
  suites. `docs/coverage.md` says so up front; a reader who forgets it will
  draw the wrong conclusion from the total.
- The measurement rewards exactly the tests this repository already prefers —
  host-side checks that run in seconds without a display — and says nothing
  about the ones it cannot count. If that starts distorting where tests get
  written, the answer is option 2, not a bigger floor.
- CI re-runs the checks a second time to measure them (concurrently, so it
  costs the `ruby-checks` job roughly one more check-group's wall clock, no
  extra runner). The alternative — measuring the existing group in place —
  would have cost the per-check step granularity that job's log is built
  around.
- The check list in `scripts/coverage_report.rb` duplicates the one in
  `.github/workflows/build.yml`; a check added to CI and not to the reporter is
  simply unmeasured, which is a silent, low-cost drift. `--list` prints what
  the reporter believes.
