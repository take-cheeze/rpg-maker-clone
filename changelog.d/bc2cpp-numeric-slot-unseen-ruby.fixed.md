- **bc2cpp** numeric flow: an op that can run Ruby without being a call (`[]=` or
  `[]` on anything but an exact Array, an operator on a non-number, string
  interpolation, hash/array splat, range or constant lookup) now resets the
  instance-variable slot facts to their whole-program value, as a call does, so a
  user `#[]=` or `#to_s` that stores a non-number into an ivar no longer leaves a
  stale numeric proof. See the ADR 0276 addendum.
