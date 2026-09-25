- **bc2cpp** now compiles the two LCF chunk-scanner `loop` bodies as direct
  EOF/terminator loops, removing two hot-only cfunc/RProc fallbacks and
  shrinking measured Wio LCF object text by 4,686 bytes while preserving
  `StopIteration#result` behavior.
