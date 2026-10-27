- **bc2cpp inlined block loops raise the interpreter's NoMethodError on a nil
  ivar.** `@list.each { }` (and `map`, `select`, `inject`, `each_with_index`,
  Hash `each`/`each_value`/`each_key`) over an ivar that the class hint names
  Array or Hash but no path had assigned raised
  `TypeError: bc2cpp: expected Array receiver for inlined #each`. Now it
  raises `NoMethodError: undefined method 'each' for NilClass`
  (`docs/bc2cpp-guarded-block-loops.md`,
  `scripts/bc2cpp/inline_nil_receiver_check.rb`).
