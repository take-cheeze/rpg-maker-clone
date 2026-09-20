- `bc2cpp` now emits runtime-guarded direct calls for polymorphic method names
  with up to 16 eligible compiled targets, covering larger families such as
  `dispose` while preserving `mrb_funcall` fallback dispatch.
