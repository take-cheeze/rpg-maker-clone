- **bc2cpp:** the compiled engine gems share one generated runtime header
  instead of each carrying its own copy of the fixed runtime helpers, so the
  link holds one definition of each. Covered by
  `scripts/bc2cpp/runtime_header_check.rb`.
