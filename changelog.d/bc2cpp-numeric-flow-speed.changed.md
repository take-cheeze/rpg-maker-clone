- **bc2cpp** (ADR 0467): NumericFlow decodes each method body once and does its own bookkeeping with fewer
  allocations. On replayed real flows it runs in about half the time, with a third of the allocated objects. It asks
  the same questions and gives the same answers, and the generated code is byte-identical. Check
  `scripts/bc2cpp/numeric_flow_speed_check.rb`.
