- **bc2cpp:** a subclass created before the compiled gem switches its
  embedding superclass to `MRB_TT_DATA` (`Class.new(C)` in a class body) is
  now switched too. Its instances were plain objects that `mrb_data_init`
  gave an embedded payload the GC neither marked nor freed (an assertion
  failure under `MRB_DEBUG`). The fixture checks now keep libmruby's
  `MRB_DEBUG`; `scripts/bc2cpp/self_new_leaf_check.rb` covers the case.
