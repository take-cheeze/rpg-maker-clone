- **bc2cpp** (ADR 0425): a slot of a frozen literal table that is itself a frozen literal (`[[1, 2].freeze, 3].freeze`)
  now takes the literal's Array or Hash class in the element model, where it was OTHER. The shipped generated code is
  unchanged. `BC2CPP_FREEZE_SLOT=0` restores the previous model. Covered by `scripts/bc2cpp/frozen_slot_check.rb`.
