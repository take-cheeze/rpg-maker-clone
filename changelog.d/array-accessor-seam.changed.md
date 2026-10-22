- Internal: project C++ code and the bc2cpp generator now read Array length and
  elements through `ary_size` / `ary_items` (`include/mrb_array_access.hxx`)
  instead of `RARRAY_LEN` / `RARRAY_PTR`. Both forward to the same mruby macros,
  so behaviour is unchanged. Covers #2555 and #2556. The vendored mruby core
  keeps its own macros. Its consumers already go through them, so no change is
  made there.
