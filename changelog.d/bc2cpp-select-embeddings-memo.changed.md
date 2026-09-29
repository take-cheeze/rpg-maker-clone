- **bc2cpp** `CodeGen#select_embeddings` reuses the memoized
  `strict_subclass?` instead of building a `Set` per owner pair. Output is
  byte-identical.
