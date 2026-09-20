- `bc2cpp` now emits an exact runtime-class guard when a polymorphic method
  has one eligible compiled target, using ordinary `mrb_funcall` for every
  other receiver class.
