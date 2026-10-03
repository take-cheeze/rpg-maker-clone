- **bc2cpp** derives the "`super` has no block-carrying caller" fact from the
  bytecode instead of carrying a hand-vetted allowlist entry for it (ADR 0332).
  A `SENDB`/`SSENDB` of the same name anywhere in the build now turns the direct
  call off for that method by itself. `BC2CPP_SUPER_DIRECT=0` restores the
  previous behaviour.
