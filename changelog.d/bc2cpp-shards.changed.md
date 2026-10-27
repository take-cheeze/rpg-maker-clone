- **bc2cpp's generated C++ compiles in parallel**: `BC2CPP_SHARDS=N` splits it into
  N translation units with one definition of every helper, cache and table
  (`docs/bc2cpp-shards.md`). The compiled engine gems and the optcarrot probe
  default to 4; the probe also stops compiling its generated file twice and runs
  its rake with `-m`. Covered by `scripts/bc2cpp/shard_output_check.rb`.
