- **bc2cpp** calls `Array#delete`, `Array#index`, `Array#compact` and `Array#__svalue` directly on a receiver the flow
  proves is exactly an Array, including the non-nil arm of a nil-or-Array split. `Array#delete` gets a hand-audited
  entry, the `index`, `compact` and `__svalue` entries are re-pinned to the current mruby bodies (they had stopped
  verifying), and `scripts/bc2cpp/native_core_direct_wired_check.rb` now fails when a hand-audited entry drifts.
