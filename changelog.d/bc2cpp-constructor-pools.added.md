- **bc2cpp constructor pools** (`BC2CPP_CONSTRUCTOR_POOLS=0` turns them off): the arguments of an `initialize` are
  now joined over every `Klass.new`, `super(...)`, implicit-self `new` of a singleton method and `self.class.new`
  of the closed world, so the ivars they are stored into carry exact classes. 38 rpg2k/LCF/RGSS constructors are
  pooled; on the wio build 25 `bc2cpp_getidx` callers and 1 `bc2cpp_send` become direct and 8 fallbacks become
  errors, with the shipped C++ byte-identical when the switch is off. New `constructor-pools` CI shard
  (`scripts/bc2cpp_constructor_pools_check.rb`, 13 mutants). See
  `docs/adr/0313-bc2cpp-constructor-pools.md`.
