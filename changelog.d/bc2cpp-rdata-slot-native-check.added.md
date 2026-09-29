- `scripts/bc2cpp_rdata_slot_native_check.rb` (CI shard `rdata-slots`) runs
  bc2cpp output with typed and boxed embedded ivars under GC pressure,
  reflection, dup and NULL-payload objects against the patch-chain mruby.
