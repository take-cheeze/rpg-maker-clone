- **bc2cpp** can compile a second, specialized body of a hot method whose parameters are monomorphic at run time but not
  provable from its call sites (`BC2CPP_SPECIALIZE=<file>`, lines `Owner#name param=Class`, e.g. from
  `BC2CPP_TRACE_PARAMS`). The original body gets one entry check in front of it (exact class: the object's own class
  pointer, a fixnum for `Integer`) and runs unchanged when it fails, so a wrong guess only costs speed. Off by default;
  with the variable unset, empty or `0` the generated C++ is byte-identical. Blocks, rescue ranges, optional, rest,
  keyword and block parameters are not specialized yet. Covered by `scripts/bc2cpp_entry_specialize_check.rb` and its
  mutation check (ADR 0379).
