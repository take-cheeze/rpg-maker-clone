- **bc2cpp** receiver-class and ivar-type walks no longer build per-call
  closures or path Arrays (hoisted barriers, a closure-free entry marker, a
  shared empty path), cutting about 2.2% of the compiler's host allocations on
  the sealed Optcarrot compile with identical generated C++. See
  `docs/bc2cpp-trace-walk-allocations.md`.
