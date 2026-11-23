- **bc2cpp:** a native C call of `mrb_mod_constants` or another `mrb_mod_const_*`
  function now keeps every constant binding, as Ruby-side constant reflection
  already did, so dropped or elided constant definitions can never be observed
  from C.
