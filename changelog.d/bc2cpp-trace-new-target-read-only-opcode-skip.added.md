- **bc2cpp** mirrors ADR 0188's read-only-opcode fix from `IvarLayout
  .trace_type` into `trace_new_target` (the shared backward-trace helper
  behind `ClassLayout`/`ArrayElementLayout`/`HashElementLayout`'s own class
  hints), so an early `return`/guard clause sharing a register slot with a
  later write can no longer wrongly poison a class hint to `OPAQUE`. Verified
  to have zero measurable effect on the real project today (`scripts/
  bc2cpp_coverage_report.rb` output byte-identical before/after, all 22
  static checks pass) -- a precision fix for future closed-world changes,
  not a currently-measurable win. See ADR 0191.
