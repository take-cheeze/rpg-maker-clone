- **bc2cpp** container shape analyses (Hash records, Array/Hash element
  layouts, sealed Hash ivars) now read the bytecode IR's producers, container
  literals and literal classes instead of walking instructions themselves
  (ADR 0502, `docs/bc2cpp-ir-containers.md`). An element register set on both
  arms of a join is now known when the arms agree. Covered by
  `scripts/bc2cpp/ir_container_shapes_check.rb`.
