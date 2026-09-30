- **bc2cpp** numeric flow: an op that can run Ruby without being a call (an
  operator on a non-number, an index on anything but an exact Array,
  string interpolation, hash or range construction, constant lookup) now
  resets the instance-variable slot facts to their whole-program value, as a
  call does. See ADR 0286.
