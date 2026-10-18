- Persist the bc2cpp native-source scan cache across CI runs (actions/cache on
  build/bc2cpp-cache) in the `bc2cpp-build` and `ruby-checks` jobs, and enable
  YJIT for the `ruby-checks` job's host Ruby, so repeated generator scans and
  host analysis are faster on warm runs.
