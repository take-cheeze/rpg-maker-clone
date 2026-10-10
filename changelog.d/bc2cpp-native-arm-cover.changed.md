- **bc2cpp** (ADR 0384): a send whose receiver set the exact-class flow proves, and whose every class either resolves
  to a Ruby definition or already has an exact-class native arm emitted ahead of the chain's else (`update` on
  Sprite, Viewport, Window), no longer keeps the by-name else. Classifies the 223 `closed_world_kept` sends
  (about 200 have an unproven receiver; the class-aware gate itself already exists in ADR 0317/0323).
  `BC2CPP_NATIVE_ARM_COVER=0` restores the old output byte for byte; checks
  `scripts/bc2cpp_native_arm_cover_check.rb` and `scripts/bc2cpp_native_arm_cover_mutation_check.rb`.
