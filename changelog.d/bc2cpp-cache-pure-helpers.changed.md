- **bc2cpp** caches pure string helpers that ran per call site or per
  instruction (`CodeGen#sanitize`, `InsnDecoder.operand_sizes`,
  `ClosedWorld#simple`) and hoists per-iteration checks out of
  `IrepScans#walk_writers`. Output is byte-identical.
