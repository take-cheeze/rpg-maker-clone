- **bc2cpp**: a method with one optional argument, a keyword rest and a block (`def f(a, b = 1, **kwd, &blk)`, such as
  `IO.popen`) compiles: the keyword rest is read from the callinfo's keyword slot, and the block is passed as the
  optional-block shape already does. A class body containing such a method no longer refuses as a whole.
