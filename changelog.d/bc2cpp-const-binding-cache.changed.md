- **bc2cpp**: a bare constant bound at several fixed paths (`Window` in RGSS and RPG2k, a `SCREEN_W` per scene) and
  a `Scope::NAME` read of an immutable constant are cached per site, once every binding the closed world lists
  exists, instead of walking the lexical scopes at every read. See `docs/bc2cpp-constant-lookup.md`.
