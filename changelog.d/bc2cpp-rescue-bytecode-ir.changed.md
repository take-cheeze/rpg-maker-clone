- **bc2cpp**: the rescue/ensure/`defined?` recognizers read jumps, region
  boundaries and instruction lookups through `BytecodeIR` (branch edges,
  region boundary breaches) instead of hand-rolled address scans. Generated
  output is unchanged.
