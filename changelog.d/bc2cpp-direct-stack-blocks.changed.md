- **bc2cpp: a direct call to a compiled Ruby method also takes the
  frame-local block.** `STACK_BLOCK` built a literal block in the caller's
  frame only for compiled core arms. A direct call to a compiled program
  method whose body only calls its block now takes it too, so
  `LCF::Array2D#each` in `Scene::Map#pages_changed?` (run every frame) and the
  `cached_bitmap` and `auto_battle_best_target` blocks no longer allocate an
  `RProc` per call. On the closed world, 15 more rpg2k block sites build their
  block in the frame, and a Nepheshel map run allocates no heap block per frame
  (was 1).
