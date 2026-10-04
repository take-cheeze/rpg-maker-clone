- **bc2cpp** `BC2CPP_RECEIVER_PROOF_REPORT` now names the admission rule an unproven parameter fails instead of a flat
  `no_candidate`, which splits a bucket ADR 0331 measured as one (ADR 0340). Of the 173 parameter rows it holds on
  master `bf25f9cc`, **91 are block parameters**, not method arguments: `Game::Battle#apply_to_party` alone
  contributed 10, and it has no parameter at all -- `|c|` is bound by `@allies.each`'s block, and the report had been
  attributing it to that method's rules. They need ADR 0312's container-element classes, not the parameter pools
  ADR 0331's trigger pointed at. The genuinely method-shaped remainder is `multidef*` (49 sites, 11 floor-freed) and
  `arity` (22, 3), each a different proof and neither at ADR 0331's 30-send cutoff, so no receiver proof is built.
  Changes no generated code; a negative control (block-parameter detection disabled) makes the check fail.
