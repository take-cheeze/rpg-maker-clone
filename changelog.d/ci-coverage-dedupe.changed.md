- **CI:** the `ruby-checks` job runs each host-side check once instead of twice.
  The checks it used to run in its own steps now run only in the coverage step
  (`scripts/coverage/report.rb`), which measures the same lines as before. The
  coverage step passes `--require-needs`, so a missing downloaded test bed fails
  its check rather than skipping it.
