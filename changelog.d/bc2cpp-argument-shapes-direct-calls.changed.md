- **bc2cpp** resolves more argument shapes to direct calls (ADR 0265): a literal
  block on a compiled callee (`page_field`, `cached_bitmap`, ...), rest and
  block-parameter callees, and literal- or runtime-sized splats (switched on the
  Array length). A `yield` inside a `rescue` body now compiles, so `page_field`
  is no longer left uncompiled. Covered by `scripts/bc2cpp_arg_shapes_check.rb`
  (interpreted-vs-compiled transcript comparison).
