- **bc2cpp**: `scripts/bc2cpp/closed_build.bash` no longer runs the whole closed-world generation twice. Its first
  phase only builds the presym list for the native return-kind analysis, so the compiled gems' outputs are empty stubs
  there (`BC2CPP_STUB_GENERATION=1`); the real generation runs once, in phase 2, with the table.
