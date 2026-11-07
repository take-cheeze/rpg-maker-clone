- **bc2cpp:** Three compiler gaps behind failing checks are closed. The `Kernel#loop` inline and direct call
  (`block_core_kernel_definition`) counted mruby's own compiled `Kernel#loop` as a program definition when the core
  mrblib is compiled and so never fired; only non-core definitions refuse it now. A literal block on a receiver the
  flow proves is exactly a Range (`(lo..hi).each { }`) bypassed the Integer-bound `bc2cpp_range_each` helper through
  the EXACT_TYPED direct call; it takes the helper again. The BLOCK_CORE_DIRECT kind_of arms (Enumerable,
  Enumerator, ...) answered an Array subclass or a class including the module with mruby's body even when the
  program defines the same name on that subclass or on a module it includes (`CmList#map`, `CmMix#select`, ...);
  any program definition of the name now withdraws those arms. `core_definer_mono_check.rb` expects the core
  Enumerable/Enumerator/Array/Hash definition, not a `<native>` placeholder, as the second POLY definer when the
  core mrblib is compiled.
