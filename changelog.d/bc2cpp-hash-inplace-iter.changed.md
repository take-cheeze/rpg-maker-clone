- **bc2cpp** (HASH_INPLACE_ITER): inlined `hash.each`/`each_value`/`each_key` loops, and inlined
  any?/all?/none?/count/index/find/map/select/reject loops over `hash.values`/`hash.keys`, read the Hash into a C
  buffer instead of building keys/values Arrays (a Hash over 16 values still gets one Array). Iteration still sees
  the Hash as it was when the loop started. Nepheshel's opening drops from 8.33 to 6.88 allocations per frame; Wio
  flash -408 B. `BC2CPP_HASH_INPLACE_ITER=0` keeps the Arrays; covered by
  `scripts/bc2cpp/hash_inplace_iter_check.rb`.
