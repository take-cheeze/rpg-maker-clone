- **bc2cpp**: a literal-block send whose name only core classes answer (the OUTSIDE_OWNER_CALL bare line, e.g.
  `@states.any? { }` or `(1..n).map { }`) now gets the site's exact-receiver proof. A receiver proven to be exactly
  an Array, Hash or Range takes BLOCK_CORE_DIRECT's single proven arm instead of three class tests; with a
  yield-free block no owner call is left at all. In the closed build 64 more sites take the proven arm and 57
  owner calls disappear.
