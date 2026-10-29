- **bc2cpp** (LOAD_COMPILE, path form): a class or module nesting header that has no kept text of its own (no def and
  no residual statement) is dropped from the residual mrblib when its constant already exists and no kept body under
  it looks up a name that scope holds; the kept bodies under it are written with their full path (`class M::Inner`).
  The proof (`tools/bc2cpp/load_compile.rb`, PATH_FORM) refuses any header whose removal would change a lookup. Check
  `scripts/bc2cpp/path_form_check.rb` (accept and refuse fixtures, five mutants that must be detected).
