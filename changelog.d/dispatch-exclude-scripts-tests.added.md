- **bc2cpp**: `tools/bc2cpp/static_dispatch_registrations.rb --exclude-scripts-tests`
  drops Ruby test files, `scripts/` and `tools/` from the dispatch scan for any
  build, without the closed-world semantics of `--closed-only` (which still
  implies it). Only `--closed-only --write` may write a table with it.
