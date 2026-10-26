- **bc2cpp**: the closed build leaves 211 more compiled methods out of the method tables (1692 → 1903). A setter,
  predicate or bang name (`x=`, `x?`, `x!`) used to stay registered whenever its base name `x` was looked up by
  name anywhere. Now that only holds when `x` was read as text, where `obj.x = 1` scans as `x`. A name from
  bytecode or a C string literal is exact. The old rule comes back if a `"="`, `"?"` or `"!"` literal may reach a
  string built at run time.
