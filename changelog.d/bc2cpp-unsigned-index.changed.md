- **bc2cpp**: the inline Array element read (`bc2cpp_ary_entry`) reads the embed flag once and tests the
  index as one unsigned compare, with a negative index counted from the end in the same unsigned arithmetic;
  the inline `x[i]` fronts test the fixnum tag only, and `bc2cpp_ary_set` stores in range only. Results are
  unchanged for every index, and the optcarrot probe runs 10.7% fewer instructions per frame. See `docs/bc2cpp-unsigned-index.md`; check
  `scripts/bc2cpp/unsigned_index_check.rb`.
