- **bc2cpp inlines a literal block's loop behind a run-time exact-class test**
  (`GUARDED_BLOCK_INLINE`, ADR 0417): `x.each { }`, `map`, `select`, `any?`,
  `each_with_index`, `Hash#each` and the other block loops that were only inlined
  for a proven receiver now also run in the method's own function for an
  unproven one when it is an exact `Array` or `Hash`, with no `RProc`, no
  `mrb_funcall_with_block` and no per-element yield. Every other receiver takes
  the code that was there before, so nothing is removed from the dynamic path
  and no reviewed-list entry changes. `BC2CPP_GUARDED_BLOCK_INLINE=0` turns it
  off. Also fixes a `break` inside an inlined `each_with_index` block, which did
  not compile as C++.
