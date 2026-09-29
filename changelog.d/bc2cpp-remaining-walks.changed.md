- **bc2cpp: `Irep#enter`, `#enter_index`, `#each_with_op` and
  `#previous_real_index`** replace the ENTER lookups, single-op instruction
  scans and the hand-rolled EXT1/EXT2/EXT3 back-stepping in the registry. The
  generated C++ is byte-identical.
