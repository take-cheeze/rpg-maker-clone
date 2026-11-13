- **bc2cpp:** `respond_to?(:name)` on a receiver of unknown class, where a core
  class such as `Proc` also defines the name, now answers `nil`, `true`,
  `false`, numbers, symbols, strings, arrays, hashes and ranges without a call.
  In the closed RPG2000 build that removes about 1,950 by-name lookups per
  3,000 New Game frames (`LCF.to_rb`'s and `LCF.elements_of`'s
  `respond_to?(:call)`).
