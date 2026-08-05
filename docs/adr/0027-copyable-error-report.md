# 27. One copyable error report on every fatal path

Date: 2026-08-05

## Status

Accepted

## Context

Until now a fatal Ruby exception was reported by printing the class, the message
and mruby's backtrace, and then quitting (`CHECK_NO_EXC` and the two
`mrb_print_backtrace` sites in `src/main.cxx`). That is enough for whoever is
sitting at a terminal with the source tree open, and close to useless for
everyone else:

- It says nothing about *which* build failed, which project was loaded or where
  in the engine the failure was caught — all of which a maintainer has to ask
  for before a report can be placed at all.
- It drops the runtime log, which is normally where the actual reason is: the
  `[RPG2k]` / `[RGSS]` lines the runtime logs when an asset is missing or a data
  field falls back to a default (the logging AGENTS.md requires) scroll past and
  are gone.
- In the browser — the way most people meet this engine, via the GitHub Pages
  build — there is no terminal at all. The backtrace lands in a collapsed
  "Runtime log" panel behind a frozen canvas, and the reporter has no plausible
  path from "it broke" to a bug report that anyone can act on.

So the failure mode was not "errors are silenced" (they are not) but "the
evidence never reaches a bug report".

## Decision

Every fatal path assembles **one self-contained Markdown report** and offers it
for copying, rather than printing fragments.

- `src/error_dump.cxx` (`include/error_dump.hxx`) builds it: the build revision
  and type stamped in at configure time, the platform, the mruby version, the
  run context (game directory, screen size, display backend, detected maker,
  the site that caught the failure), the exception with its backtrace, and the
  runtime log tail. `error_dump_report` prints it between
  `----- BEGIN RPG MAKER CLONE ERROR REPORT -----` / `----- END ... -----`
  markers, writes it to the `--error_dump` file (default `error-report.md`;
  empty disables) and hands the text back.
- The log tail is captured in Ruby: `RGSS::ErrorReport`
  (`mruby-rgss/mrblib/error_report.rb`) tees `$stderr` through a bounded ring
  buffer at start-up. `$stderr` is the runtime's logging convention, so this
  needs no change at any of the ~180 existing call sites, and every write still
  reaches the real `$stderr` untouched.
- The browser shell (`src/shell.html`) watches its log for the markers, folds
  the engine's report together with what only the page knows (address, browser,
  loaded project, its own log tail) and shows it in an error panel with **Copy
  error report** / **Download**. The same report is available without a crash
  under *Runtime log → Copy diagnostics*, and page/wasm errors
  (`window.onerror`, unhandled rejections, `Module.onAbort`) go through the same
  panel.

Markers were chosen over an exported `rpg_error_dump()` the page would `ccall`:
the report already has to reach stderr for the desktop case, the page already
mirrors stderr, and scraping keeps the JS side working for aborts where calling
back into the runtime is not safe.

The report path is tested rather than assumed, because a report that quietly
lost half its content is worse than no report and is only discovered when a
crash has already happened:

- `--error_dump_probe` (the `error_dump` ctest) raises a real exception through
  the real path in the real binary and asserts the report still carries the
  exception, a backtrace naming the raising frame, the log line written before
  the raise and the run context, and that the written file matches what was
  printed.
- `scripts/error_report_check.rb` checks the capture itself on CRuby (partial
  writes, bounding, truncation, forwarding, single installation), and
  `mruby-rgss/test/test.rb` asserts the same behaviour inside the built
  interpreter.

## Consequences

- A player can report a crash by pasting one block, from the browser, with no
  tooling. A maintainer gets the build, the project and the log without a
  round-trip.
- The desktop run writes `error-report.md` into the working directory on a
  crash. It is overwritten per crash and disabled with `--error_dump=`.
- The revision in the report is stamped at **configure** time, not build time:
  committing without re-configuring leaves it pointing at the older commit.
  Re-running git on every build would rebuild the world on every commit, and CI
  configures a fresh checkout per run, so its reports name the exact commit.
- The tee means `$stderr` is no longer the object mruby-io created. It forwards
  everything and delegates the rest of the IO surface, but code that checks
  `$stderr.is_a?(IO)` (nothing does today) would see the tee instead.
- The markers are a contract between `include/error_dump.hxx` and
  `src/shell.html`; changing one without the other silently loses the browser
  panel. Both files say so.
- The native `start` path now returns `EXIT_FAILURE` after reporting instead of
  aborting through ng-log's `CHECK`, so a crash exits cleanly (1) rather than on
  a signal, with the report as the last thing printed.
- Not done here: copying to the system clipboard from the desktop build. X11 and
  Wayland hand clipboard ownership to the running process, so a report copied on
  the way out would vanish with it — the file is the honest answer there.
