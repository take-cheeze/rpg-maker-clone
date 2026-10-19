- **bc2cpp** (ADR 0280): the exact-receiver, `===`, `times` and literal-block Integer proofs now ask one
  BytecodeIR query, `BytecodeIR::Types#exact_at`, instead of each walking back to a dominating literal.
  The query takes only literal facts: a literal of one class on every reaching path, through joins, loops and
  rescue/ensure ranges, with `ARYPUSH`/`HASHADD`/`ARYCAT`/`HASHCAT`/`STRCAT` passing their container's
  class through. On the rpg2k, lcf and rgss sources no proof is lost; 39 receiver sites and one
  Integer `times` receiver are proven in addition. New host check `scripts/bc2cpp/ir_exact_types_check.rb`.
