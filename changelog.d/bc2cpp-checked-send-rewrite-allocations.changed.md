- **bc2cpp** `CheckedSend` rewrites a marked call head with a byte search instead
  of two per-site `Regexp`s and `gsub` copies, about 1.2% fewer compiler
  allocations on the sealed Optcarrot workload. Output is byte-identical; see
  `docs/bc2cpp-send-emission-allocations.md`.
