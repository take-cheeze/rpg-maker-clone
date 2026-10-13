- The nightly `bc2cpp-checks (optcarrot-benchmark)` shard runs its five compiled
  checksum benchmarks as a `ci:parallel` group of three. `compiled_run.rb` takes
  `OPTCARROT_WORK_DIR`: the run then builds in a digest-checked copy of the
  patched `3rd/mruby` under that directory, and only checks the patches instead
  of applying them, so the runs share no build directory. Unset, the script
  behaves as before. Each run writes its own job-summary file, appended in order
  after the group (docs/ci.md, "Parallel groups").
