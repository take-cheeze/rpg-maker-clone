- **bc2cpp** reuses immutable receiver-class snapshots in native-result proofs
  and tests single-bit membership without temporary bignum intersections,
  reducing allocations while preserving class discovery and probe rollback.
