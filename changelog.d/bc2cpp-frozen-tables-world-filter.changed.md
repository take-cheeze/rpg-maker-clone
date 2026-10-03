- **Frozen-tables check runs only the worlds a mutant can be killed by.**
  `bc2cpp_frozen_tables_check.rb` now names every world it generates and takes
  `FT_WORLDS=slug[,slug...]` to run a subset, and
  `bc2cpp_frozen_tables_mutation_check.rb` names the one or two worlds each
  mutant's own check lives in. The mutation check goes from 111s to ~10s
  (673s before it was parallelised), which with the unfiltered check's cost
  takes the `core-tables` shard from ~10 min to roughly 6. An unknown world
  name is a hard error, and pointing a mutant at a world that cannot kill it
  is reported as surviving, so the filter cannot hide a mutant.
