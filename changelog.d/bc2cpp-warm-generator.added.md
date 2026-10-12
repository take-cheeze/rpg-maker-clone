- **bc2cpp** can serve the fixture checks' generator runs from a warm server that forks one generation per run,
  behind `BC2CPP_WARM_GENERATOR=1` (off by default; output is byte-identical to one process per run). See
  ADR 0416 and `scripts/bc2cpp/warm_generator_check.rb`.
