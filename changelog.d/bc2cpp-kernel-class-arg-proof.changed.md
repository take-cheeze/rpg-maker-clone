- **bc2cpp**: `is_a?` and `kind_of?` omit redundant argument guards and dispatch
  fallbacks for proven stable class/module constants. Dynamic arguments and
  reassigned or non-class constants retain their original checks.
