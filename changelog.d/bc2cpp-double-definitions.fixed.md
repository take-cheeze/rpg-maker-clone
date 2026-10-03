- **bc2cpp** compiled a class that defines one name twice differently from the interpreter, which runs the last
  definition: `attr_reader` then `define_method` (or `def`), `alias`/`alias_method` over a `def`, a `def` then
  `define_method`, `module_function` over a redefined `def` called the dead body; a `def` twice, a reopened class or
  `def self.m` twice failed the C++ build with a redefinition, as did an instance method and a singleton method
  whose names join to one symbol (`singleton_make` and `self.make`). The registry now keeps the last definition of
  each (owner, name), withdraws the name when the last one may not run, and gives clashing symbols a `$n` suffix
  (ADR 0319). The shipped output of every compiled gem is unchanged.
