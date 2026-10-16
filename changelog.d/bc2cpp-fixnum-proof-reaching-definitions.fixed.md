- **bc2cpp**: the Fixnum operand proof now asks the shared reaching-definitions analysis. The proof's own fallback
  could miss a loop-carried write (`i -= 1` in `downto`, `bsearch_index`, `Range#each`) or read a write from a branch
  that jumps away. The analysis also treats a `break` JMPUW outside `ensure` as a plain jump and ignores unreachable
  predecessors (ADR 0476).
