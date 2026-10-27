- **bc2cpp**: EMBED_INIT_GUARD fails the build when an owner whose ivars are embedded is emitted without the compiled
  `#initialize` that allocates their storage (missing, or dropped by `SKIP_UNSUPPORTED`). The embedding is chosen from
  a probe compile; until now nothing checked the final output agreed, and a disagreement would have meant compiled
  methods reading `DATA_PTR` of a plain object. See `docs/bc2cpp-embed-families.md`.
