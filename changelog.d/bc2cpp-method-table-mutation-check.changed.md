- **bc2cpp: the method-lookup seam is checked against run-time table writes.**
  `owner_lookup_shapes_check.rb` now calls warm owner-call sites across
  `define_method`, `remove_method`, `alias_method`, `undef_method`, include,
  prepend, extend, visibility changes, `method_missing` and core redefinition,
  and requires the compiled output to equal the interpreter's. The Phase 1 plan
  records why a registration-time table cannot be sound without a method-table
  write signal from mruby, and the smallest upstream change that would give one.
