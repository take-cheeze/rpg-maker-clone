- **bc2cpp** (ADR 0431): `&`, `|` and `^` of two proven Integers are now a proven Integer result, so `+`, `-` and `*`
  on such a result can use the core body without a dynamic-send else. `<<` and `>>` are unchanged, and the shipped
  build's output does not change. `BC2CPP_BITOP_RESULTS=0` restores the previous output. Check
  `scripts/bc2cpp/bitop_results_check.rb`.
