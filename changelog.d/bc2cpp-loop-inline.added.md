- bc2cpp inlines `loop do ... end` (LOOP_INLINE) as a native `for (;;)` in the method body. Before, it called the
  compiled `Kernel#loop`, where every `break` was a C++ exception thrown through it. The pass runs only when nothing
  in the program can raise `StopIteration` into the loop: the program sends no `Enumerator#next`-family method and
  never raises the class itself. See `docs/bc2cpp-loop-inline.md`; checked by `scripts/bc2cpp/loop_inline_check.rb`.
