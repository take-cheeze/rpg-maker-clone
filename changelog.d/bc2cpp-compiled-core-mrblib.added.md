- **bc2cpp compiles mruby's own Ruby** (`mruby-core-compiled`, ADR 0264): the block-free
  methods of core mrblib, the core gems' mrblib and mruby-stringio/onig-regexp
  (56 in the wio gem set) are compiled and registered over the bytecode for the
  RPG2000/2003 maker. Methods that take or yield to a block, use the Fiber class or
  come from mruby-enumerator stay bytecode, since a `Fiber.yield` inside a block cannot
  cross a compiled frame. `positive?`/`negative?` and other core names without a native
  definition now resolve to direct calls in engine code (467 -> 449 generic dispatch
  sites in engine methods); wio/psp/maix builds compile none. New checks:
  `scripts/bc2cpp_core_mrblib_check.rb` (compiled bodies vs the interpreter, 3,821 cases)
  and `scripts/bc2cpp_core_mrbtest.rb` (mruby's own `rake test`, interpreted vs compiled).
