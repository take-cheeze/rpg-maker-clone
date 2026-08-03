- **AGENTS.md** now documents the pull-request workflow agents should follow —
  one focused change per `claude/…` branch, running pre-commit formatting,
  adding a `changelog.d/` fragment, recording an ADR for architectural changes,
  running the CTest/`scripts/*_check.rb` suites, and keeping CI green.
