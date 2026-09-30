- **bc2cpp** compiled `begin ... rescue` bodies no longer lose the locals they
  assign: the handler and the code after the region saw the value from before
  the `begin` (a rescued load logged an empty file name, `y = x.succ` inside a
  rescued block returned the stale `y`). Such locals are now shared with the
  extracted try body by reference.
