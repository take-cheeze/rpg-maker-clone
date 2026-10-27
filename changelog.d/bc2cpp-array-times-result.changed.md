- **bc2cpp**: `ary * n` with an Integer `n` is known to be a fresh, exact Array, so an ivar sized as
  `@cells = [0] * 8` gets an Array class pool and its index reads drop the class test
  ([ARRAY_TIMES_RESULT](docs/bc2cpp-array-times-result.md)). The fact checks the audited `mrb_ary_times` body
  and that nothing gives Integer a `to_str` or an ancestor of Array a `*`. In the optcarrot probe, on top of the
  ivar proof scope change, the frame loop drops from 32.19M to 30.59M instructions per frame (callgrind).
  `BC2CPP_ARRAY_TIMES_RESULT=0` drops the fact. New check `scripts/bc2cpp/array_times_result_check.rb`.
