- **bc2cpp** declares the blockless `map`/`collect` of Array and Hash as the
  method-level union of two overloads: `Enumerator[untyped, untyped]` without a
  block, `Array[untyped]` with one. The block-form result table reads the
  overload that takes a block; the blockless result is not yet typed by codegen.
