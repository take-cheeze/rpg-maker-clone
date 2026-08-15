# Code coverage

Almost all of the runtime is Ruby: the LCF and RGSS data layers, the RPG2000
game logic and its scenes, the MV/MZ core — about 39 000 lines under
`mruby-*/mrblib`, against roughly 3 000 lines of C++ glue in `src/`. That Ruby
is written in the mruby/CRuby common subset and the `scripts/*_check.rb`
harnesses load it under CRuby (see any harness header), which is what makes it
measurable: CRuby ships a `Coverage` module, mruby does not.

`scripts/coverage_report.rb` runs those harnesses with coverage switched on and
reports which lines they reached.

```sh
ruby scripts/coverage_report.rb            # run every check, write coverage/
ruby scripts/coverage_report.rb --per-file # ... listing every file
ruby scripts/coverage_report.rb --only rpg2k   # just the rpg2k-* checks
ruby scripts/coverage_report.rb --list     # what it would run
```

Output:

```
Ruby line coverage

  mruby-lcf      #################.......   68.8%     271 / 394
  mruby-mvjs     ........................    0.0%       0 / 1064
  mruby-rgss     ##......................    9.5%      72 / 761
  mruby-rpg2k    ######################..   92.9%   11305 / 12175
  mruby-rpgvx    ####################....   85.1%     308 / 362
  mruby-rpgxp    ##################......   73.7%     777 / 1054
  total          ###################.....   80.5%   12733 / 15810
```

plus, in `coverage/`:

- `lcov.info` — the standard interchange format. `genhtml coverage/lcov.info -o
  coverage/html` renders a browsable per-line report, and coverage services
  (Codecov, Coveralls) read it directly.
- `coverage.json` — the same numbers per gem and per file, plus the status of
  every check that was run, for scripting.

## How it works

`Coverage.start` has to run before the sources are loaded, so
`scripts/coverage_hook.rb` is injected into each check with
`RUBYOPT=-r<hook>` instead of being required by the harnesses. The harnesses
stay untouched, any `ruby` a harness spawns is measured too, and each process
dumps its own result as JSON into a temporary directory that the reporter then
merges. Checks run concurrently (`--jobs`, default: processor count).

Files that no check ever loads do not appear in a `Coverage` result at all;
they are added at 0% from `Coverage.line_stub`, so a whole untested file drags
the total down instead of silently vanishing from it.

## What the number does and does not mean

It is a **floor**, not a ceiling. Two other test suites exercise the same Ruby
and cannot be counted:

- `mruby_test` (`cmake --build build -t test`) runs each gem's own tests inside
  mruby, where there is no `Coverage` module.
- The native smoke tests (`scripts/*_boot_check.bash`, the MV/MZ runs in CI)
  drive the built binary, likewise inside mruby.

So a file reported at 0% is not necessarily untested — `mruby-rgss/mrblib/lib.rb`
and `mruby-mvjs/mrblib/{mv,mz}.rb` read as 0% because they need a live RGSS
window or a JS engine, which is exactly why no CRuby harness loads them. Read
the report as "this much of the engine is covered by the host-side checks", and
use the per-file tail as a list of where the next host-side check would pay off.

C++ coverage (`src/**.cxx`) is not wired up: those files are SDL/mruby/LVGL
glue reachable only through the display-bound smoke tests, and gcov tooling is
not in the dev shell. See ADR 0049 for that trade-off.

## In CI

The `ruby-checks` job runs the report after its check group and publishes it
two ways.

On the run's **summary page** (`$GITHUB_STEP_SUMMARY`): the headline
percentage and the per-gem table, then two collapsed sections — the least
covered files, and every check with its result and duration (including the
ones that skipped, and why). No log-digging to see the number.

As a **`ruby-coverage` artifact**: `lcov.info` and `coverage.json`, the whole
per-file picture, for `genhtml` or a coverage service.

The **number** is report-only
— no floor is enforced, so coverage moving does not fail a build. The step
itself is an ordinary one: a broken reporter, or a check that fails only under
the coverage re-run, fails the job rather than silently producing no report.

To make it a gate instead, pass a floor:

```sh
ruby scripts/coverage_report.rb --min-line-rate 75
```

which exits non-zero when total line coverage falls below it. The reporter also
exits non-zero when a check it ran fails, so it is honest about a broken check
rather than reporting a coverage number computed from a half-finished run.

Checks needing data that is not committed (the RPG2000 event-command soak wants
a downloaded test bed) are reported as skipped rather than failing, so the
report is runnable in a fresh clone; the coverage they contribute is simply
missing from it. CI downloads those games, so its numbers are the complete ones.
