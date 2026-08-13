- **A fire-and-forget Move Event's forced route now implicitly auto-runs to
  completion the instant the same event hits a Show Text or a Wait**, rather
  than sitting frozen with zero progress until the whole event finishes. No
  explicit "Proceed With Movement" is needed for this — matching yado.tk's
  documented rule that only forcing it *mid-list* needs that command.
