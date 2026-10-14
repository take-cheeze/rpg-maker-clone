- **bc2cpp** extends RBS-aware IR queries to ivars, inherited contracts and
  implicit self-call return types. Type-check reports now expose provenance,
  refusal reasons and return/ivar compatibility diagnostics, and
  `--emit-rbs-suggestions DIR` exports independently inferred return candidates
  for review and feedback into RBS files.
