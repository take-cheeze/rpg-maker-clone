- **bc2cpp** loop/block-region recognizers now read the shared `BytecodeIR`
  graph: one `each_block_site` skeleton replaces the eleven copies of the
  BLOCK/SENDB adjacency scan, and the op, jump-target and MOVE-chain scans in
  the region, inline and block-fallback passes use `BytecodeIR` queries
  (`tools/bc2cpp/bytecode_ir_regions.rb`). Generated output is unchanged.
