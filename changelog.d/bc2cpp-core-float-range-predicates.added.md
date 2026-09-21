- bc2cpp generates `Float#infinite?` and `Range#exclude_end?` from mruby core C
  behind immediate-Float and exact-Range guards, and retains normal Ruby
  dispatch for other receivers and for Ruby overrides.
