- bc2cpp now calls the compiled method directly for a polymorphic name with
  more than 16 compiled definitions, the limit of the class-check chain.
  Every call site of the name shares one lookup table that maps a class to
  its compiled method, with a small memo of recent lookups. Classes the table
  does not list still go through `mrb_funcall`. On the full (non-hot-only)
  build this covers `update`, the only such name: 33 sites and 19 classes,
  with a direct call measured at 82 instead of 285 instructions. Generated
  code for names at or under the limit is byte-identical. Covered by
  `scripts/bc2cpp_poly_table_check.rb`; see docs/adr/0227.
