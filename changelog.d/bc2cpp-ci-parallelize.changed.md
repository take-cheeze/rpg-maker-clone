- **CI:** the `bc2cpp` job is split into a parallel job graph. `bc2cpp-build`
  compiles the full `RPGMAKER_BC2CPP=1` host libmruby with `rake -m`, and seven
  `bc2cpp-checks` shards, each building only the gem-free bootstrap host `mrbc`
  (new `mruby_host_mrbc` CMake target / `host_mrbc` rake task), run the same
  checks, coverage reports and Optcarrot benchmark alongside it. A `bc2cpp`
  aggregator keeps the old status-check name. The three compiled gems'
  codegen tasks now declare the `mrbc` they run as a prerequisite. See
  ADR 0228.
