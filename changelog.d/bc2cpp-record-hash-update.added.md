- **bc2cpp**: RECORD_HASH_PROOF now models `@slot.update({...})` / `merge!` of a
  fresh Symbol-keyed Hash literal as one store per pair instead of an escape, so
  a record extended this way is proven without an RBS record declaration. On the
  closed world it admits `@ui` in `RPG2k::Scene::Battle` (51 keys, 285 reads,
  187 stores), which its checked RBS record declaration already supplied: the
  shipped C++ is byte-identical with the step on or off
  (`BC2CPP_RECORD_HASH_UPDATE=0`). Checked by
  `scripts/bc2cpp/record_hash_update_check.rb`.
