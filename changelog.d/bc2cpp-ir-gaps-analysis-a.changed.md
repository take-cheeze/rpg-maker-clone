- **bc2cpp** (internal): the registry, RBS record and parameter checks, computed-send names, alias sites, type facts
  and loop installers now read instructions through the bytecode IR (`source_at`, `each_source`, `each_with_op`,
  `branch_target_addrs`) instead of indexing `irep.instructions` directly. Generated output is unchanged.
