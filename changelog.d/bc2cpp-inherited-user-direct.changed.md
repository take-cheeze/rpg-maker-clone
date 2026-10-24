- **bc2cpp** extends the inherited Kernel/BasicObject direct calls (`nil?`, `class`, `dup`, `equal?`, `is_a?`,
  `kind_of?`, `frozen?`, `freeze`) to receivers proven to be exactly a project or RGSS class, when no class on the way
  up to the core ancestry defines or mixes in the name.
