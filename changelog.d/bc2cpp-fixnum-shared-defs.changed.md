- **bc2cpp** Fixnum proof walks borrow shared reaching-definition results
  instead of copying the result Array and Definition objects per query,
  preserving mutable-input, bound and sharing-opt-out behavior.
