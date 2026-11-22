- The bc2cpp-compiled engine is about 190 KB smaller on the Wio Terminal: the
  heap-Integer and Float compare arms, `Integer#/`, `mrb_as_int` and block
  register addresses no longer expand an out-of-line Integer read at every site.
