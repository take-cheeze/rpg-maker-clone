- **mruby: exact Integer comparison and Array Hash keys.** `3rd/mruby` moves to
  the fork's `claude/numeric-exact-compare-r5t2` (`9153127`), which adds three
  patches: `(1 << 64) == 0` is no longer true; `<=>`, `<`, `Array#sort` and
  Hash keys are exact for Integers past the inline fixnum range
  (`2**62 <=> 2**62 + 1` was 0, and `Range#each` stopped about 512 short of an
  inclusive end at `MRB_INT_MAX`); and Array Hash keys are compared without
  dispatching `Array#eql?`.
