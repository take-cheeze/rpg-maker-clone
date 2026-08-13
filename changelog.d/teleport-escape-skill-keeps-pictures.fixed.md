- **A Teleport/Escape field skill's warp no longer clears shown Pictures.**
  `Scene::Map#perform_teleport` unconditionally erased every shown picture on
  any map change, but yado.tk documents the Teleport/Escape skill/item's own
  warp as a deliberate exception to that rule — only an ordinary map change
  (the Transfer Player / Recall to Location event commands) clears pictures.
  `perform_teleport` now takes a `keep_pictures:` flag, set from the
  `@state.pending_teleport` call site the field skill's warp is applied
  through; the interpreter's own `:teleport` wait (Transfer Player / Recall
  to Location) keeps clearing pictures as before. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code.
