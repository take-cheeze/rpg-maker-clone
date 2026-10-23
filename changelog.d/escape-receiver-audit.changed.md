- **Escape analysis** (`bc2cpp`) now knows that `class`, `is_a?`, `kind_of?`, `instance_of?`, `frozen?`,
  `respond_to?`, `hash`, `instance_variable_get`, `inspect` and `to_s` do not keep their receiver, after
  reading each native body in the vendored mruby and the RGSS sources. `respond_to?` also checks the
  `respond_to_missing?` it may call. Literal Arrays, Strings and Hashes that only pass through these calls can
  now be placed on the frame, so the generated code for those sites changes.
