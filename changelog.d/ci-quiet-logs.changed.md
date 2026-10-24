- **CI logs**: `bc2cpp-build` now prints only failed commands. Passing checks
  keep just their row of the timing table (`scripts/ci/timed_checks.rb`), and
  the closed-world build prints a one-line summary unless it fails
  (`scripts/ci/quiet_run.bash`). Annotations still get through, and
  `CI_VERBOSE=1` restores the full output. See `docs/ci.md`, "Quiet output".
