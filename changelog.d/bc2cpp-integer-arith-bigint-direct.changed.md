- bc2cpp: the `+`/`-`/`*` fallback runs mruby's own `mrb_num_add/sub/mul` (the body of
  `Integer#+` etc.) for any Integer receiver (Fixnum or bigint) with a Fixnum, bigint or
  Float operand instead of a dynamic send; other receivers keep the send.
