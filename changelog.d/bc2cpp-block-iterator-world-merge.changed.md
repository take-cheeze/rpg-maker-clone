- **bc2cpp** `block_iterator_direct_check.rb` proves the `String#each_char` and
  `Array#index` program-redefinition withdrawals in one closed-world generation
  instead of two: the two deltas redefine methods on disjoint lookup chains, so
  neither disturbs the other's arm proof, and both assertions read the same
  emitted code as before. Eight world generations become seven.
