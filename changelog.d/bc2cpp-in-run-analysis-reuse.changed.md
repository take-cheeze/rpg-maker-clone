- **bc2cpp** (ADR 0461): a whole-program pass reuses two answers it used to recompute: a receiver-specific return-class
  query that found no class is cached when no recursion cycle was cut while it was answered, and each outside Ruby
  file's defined names are scanned once per run instead of once per asked name. The wio shipped pass goes from 236 s
  to 112 s with byte-identical generated C++.
