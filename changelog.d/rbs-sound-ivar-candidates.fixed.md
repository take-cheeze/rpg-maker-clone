- **bc2cpp type-check**: an inferred ivar candidate is now the union of the
  stores across the ivar's superclass/include/prepend family and includes `nil`
  when a read can run before any store, instead of the type of a single store.
  Ivars with an unresolved store, or one written outside any class's method,
  report no candidate.
