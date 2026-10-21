- **bc2cpp** proves a block-carrying `select`/`reject`/`map` result is an Array from the receiver's
  block-form result in `core_block_iterators` (declarations.rbs), not from a name list. `map` on a receiver it
  cannot prove (for example an untyped argument, which may define its own `map`) is no longer assumed to be an Array.
