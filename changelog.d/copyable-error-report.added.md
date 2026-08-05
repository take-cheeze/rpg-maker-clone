- **Copyable error reports.** A fatal Ruby exception now produces one
  self-contained Markdown report — the exception and its backtrace, the build
  revision and type, the platform, the loaded project, where the engine caught
  it, and the tail of the runtime log — instead of a bare backtrace. In the
  browser a crash raises an error panel with **Copy error report** / **Download**
  (and *Runtime log → Copy diagnostics* for problems that do not crash the
  game); on the desktop the report is printed between `----- BEGIN RPG MAKER
  CLONE ERROR REPORT -----` markers and written to `error-report.md`
  (`--error_dump`). The log tail is captured by `RGSS::ErrorReport`, which tees
  `$stderr` through a bounded ring buffer. Checked end to end by the new
  `error_dump` ctest (`--error_dump_probe` raises a real exception and reads the
  report back) and by `scripts/error_report_check.rb`. See
  `docs/adr/0027-copyable-error-report.md`.
