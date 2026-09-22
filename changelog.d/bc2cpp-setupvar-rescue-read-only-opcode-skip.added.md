- **bc2cpp** extends ADR 0188/0191's read-only-opcode fix to `SETUPVAR` and
  `RESCUE` in both `IvarLayout.trace_type` and `trace_new_target`, closing a
  pre-existing gap in the latter's hoisted register filter along the way
  (a trace of `RESCUE`'s real write register was silently unreachable
  before this fix). Verified zero measurable effect on the real project
  today (`scripts/bc2cpp_coverage_report.rb` output byte-identical, all 22
  static checks pass) -- a precision fix for future closed-world changes.
  See ADR 0192.
