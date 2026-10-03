- **bc2cpp** `BC2CPP_BLOCK_SEND_REPORT=FILE` (ADR 0325) writes one row per block send with what keeps its dynamic
  `mrb_funcall_with_block` (unproven receiver, no compiled callee, no direct entry), and
  `scripts/bc2cpp_block_send_report.rb` aggregates it. It changes no generated code. The ADR measures four levers for
  the 282 engine block sends that still dispatch by name (SENDB call facts 0, `Array.new { }` 11, break/return direct
  entries 8, `delete` 10: 29 in all, below the cutoff), so none was built.
