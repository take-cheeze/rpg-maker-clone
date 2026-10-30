- **bc2cpp** skips element-read root analysis and final text cleanup for
  eligibility probes whose discarded text needs no runtime-definition audit,
  reducing whole-generator allocations while preserving final emitted code.
