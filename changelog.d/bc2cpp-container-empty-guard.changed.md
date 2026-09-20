- **bc2cpp** now devirtualizes `Array#empty?`, `Hash#empty?`, and `String#empty?`
  for exact base-class receivers, preserving Ruby dispatch for overrides.
