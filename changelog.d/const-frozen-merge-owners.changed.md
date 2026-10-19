- **bc2cpp type check**: a constant that is a `.freeze`d Array or Hash, or a one-argument `Hash#merge` of a Hash, now
  reports its container type when the methods involved are stock. `freeze` is scoped to the owners it can reach
  (Array or Hash, their modules, Object and Kernel), so a program's own `Graphics.freeze` no longer withholds the
  Array-sum proof. Report-only: generated code is unchanged. Covered by `scripts/bc2cpp/const_frozen_merge_check.rb`.
