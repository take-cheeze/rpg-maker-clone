- `tools/bc2cpp/bc2cpp.rb`: `iterator?` in a compiled method now reads the
  method's block like `block_given?` (it always answered false), and
  `block_given?` inside an inlined `Integer#times` body no longer emits an
  undeclared register that broke the C++ build. New
  `scripts/bc2cpp_proc_call_block_given_check.rb` compares 109 proc-call and
  block-query scenarios against the interpreter. See docs/adr/0266.
