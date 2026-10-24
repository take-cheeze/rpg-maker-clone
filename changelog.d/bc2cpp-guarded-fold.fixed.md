- **bc2cpp: `reduce(init) { }` runs as a loop on an unproven Array, and a
  Symbol initial value is no longer folded.** A fold on a receiver whose class
  is not proven now gets the guarded loop (an exact-Array test in front of the
  send), as `each` and `map` already did: `Enumerable#inject` is not compiled,
  so there was no arm to gate it. A fold, proven or guarded, also needs its
  initial value proven not to be a Symbol, because mruby's `inject` takes a
  Symbol as the operator and ignores the block: `[1, 2, 3].reduce(:+) { |m, x| m * x }`
  is 6, but the compiled loop raised `NoMethodError`.
