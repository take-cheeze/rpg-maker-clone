- **bc2cpp** gets one shared escape analysis (`tools/bc2cpp/escape_analysis.rb`, ADR 0316): a forward may-alias
  flow over registers with callee summaries, sound by construction (everything it cannot name escapes) and only
  installed in a closed world. Its first consumer, BLOCK_FALLBACK_PROVEN, lets a literal block that captures locals
  go to a callee outside `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` when every definition the call can reach provably keeps
  neither the block nor anything that reaches it (`Array#combination` now compiles). `BC2CPP_ESCAPE_ANALYSIS=0`
  gives the earlier output byte for byte; `BC2CPP_ESCAPE_REPORT=<tsv>` plus `scripts/bc2cpp_escape_report.rb`
  measure every creation site. Covered by `scripts/bc2cpp_escape_analysis_check.rb` and its mutation check.
