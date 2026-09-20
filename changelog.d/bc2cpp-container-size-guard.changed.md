- **bc2cpp** now devirtualizes `Array#size` and `Hash#size` for exact base
  receivers, while preserving Ruby dispatch for String and overrides.
