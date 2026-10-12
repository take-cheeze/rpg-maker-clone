- **bc2cpp** initializes argument registers directly and omits unreferenced
  nil-only register declarations in ordinary methods and fallback blocks,
  reducing generated C++ without changing captured or resumable register storage.
