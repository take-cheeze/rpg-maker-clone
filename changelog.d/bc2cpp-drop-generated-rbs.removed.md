- **bc2cpp's `generated/bc2cpp` RBS mirrors are gone.** `core_direct.rbs` and
  `rgss_direct.rbs` restated the `NativeCoreDirect` and `NativeDirect`
  tables, nothing loaded them, and two checks only kept them fresh. The
  tables in `tools/bc2cpp` stay the source. `scripts/bc2cpp/trace_merge.rb`
  now writes its proposals to `build/trace_proposals.rbs` by default.
