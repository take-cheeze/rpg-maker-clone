- **bc2cpp** reuses parsed native signature marker comments in a bounded cache,
  reducing repeated String and MatchData allocations while preserving member
  overrides, inherited membership and mutable-comment behavior.
