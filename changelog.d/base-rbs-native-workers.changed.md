- **Base RBS generation** scans native sources in a bounded process pool,
  defaulting to at most two workers. Both generator commands accept `--jobs N`;
  source ordering, diagnostics and generated declarations remain deterministic.
