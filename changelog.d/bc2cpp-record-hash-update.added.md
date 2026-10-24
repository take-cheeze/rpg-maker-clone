- **bc2cpp**: RECORD_HASH_PROOF now models `@slot.update({...})` / `merge!` of a
  fresh Symbol-keyed Hash literal as one store per pair instead of an escape.
  On the closed world this admits `@ui` in `RPG2k::Scene::Battle` (51 keys,
  285 reads, 187 stores), so its `@ui[:key]` reads get unguarded key classes.
  `BC2CPP_RECORD_HASH_UPDATE=0` restores the old behaviour; checked by
  `scripts/bc2cpp/record_hash_update_check.rb`.
