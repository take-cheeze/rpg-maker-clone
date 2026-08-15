- Code coverage reporting for the Ruby engine sources. `ruby
  scripts/coverage_report.rb` runs the host-side `scripts/*_check.rb` harnesses
  with CRuby's `Coverage` stdlib enabled and reports line coverage of
  `mruby-*/mrblib` per gem and per file, writing `coverage/lcov.info` (for
  `genhtml` or a coverage service) and `coverage/coverage.json`. CI's
  `ruby-checks` job publishes the table in its job summary and the files as the
  `ruby-coverage` artifact. See `docs/coverage.md` and ADR 0049.
