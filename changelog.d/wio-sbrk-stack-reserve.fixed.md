- **Wio Terminal**: the heap on the real board now stops 8 KB short of the
  stack, as it already did under Renode, instead of growing into it. A growth
  it refuses makes mruby collect and retry, then raise `NoMemoryError`, logged
  with a `[Wio] heap:` line.
