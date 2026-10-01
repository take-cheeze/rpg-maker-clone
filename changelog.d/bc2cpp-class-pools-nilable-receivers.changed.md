- **bc2cpp class pools (ADR 0296).** The exact-class flow of ADR 0289 now reads instance variables
  and arguments across methods: an ivar every writer of the closed world gives one class (or nil),
  and an argument every visible call site passes one class to, carry that class into the callee. A
  receiver proven exactly one class loses its class guard and its by-name fallback; a receiver
  proven nil-or-one-class (`@ui = nil` / `@ui = {}`, `@interpreter`) takes one `nil?` test and the
  exact path, with the nil NoMethodError as a `bc2cpp_nil_receiver` arm instead of a send. On the
  wio closed world the dynamic `bc2cpp_send` sites drop by about 17%. Withdrawn by attr_writers,
  reflection, foreign sources, singleton makers, `allocate`, computed or aliased names, and
  `BC2CPP_CLASS_POOLS=0`; covered by `scripts/bc2cpp_class_pools_check.rb` and
  `scripts/bc2cpp_class_pools_mutation_check.rb`.
