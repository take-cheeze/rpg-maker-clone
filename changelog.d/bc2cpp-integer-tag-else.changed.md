- **bc2cpp** (ADR 0394): the by-name else of an index's Integer-tag test (`x[k]`, `x[k] = v`) on an exact Array
  receiver now calls the native Array body directly (`mrb_ary_aget1_impl` / `mrb_ary_aset2_impl`) when the
  closed world proves no other definer answers `[]` / `[]=` on Array's ancestry. On the wio closed world this
  removes 111 by-name sends (106 `[]`, 5 `[]=`); the 30 Integer-tag else sites left are 25 `inspect` (Kernel's native
  definer makes the set unbounded) and 5 other sends (push, unshift, sort, div). `BC2CPP_INTEGER_TAG_ELSE=0` restores the old output
  byte for byte. Checks `scripts/bc2cpp_integer_tag_else_check.rb` (generated code and mutant) and
  `scripts/bc2cpp_integer_tag_else_run_check.rb` (real mruby, against the interpreter).
