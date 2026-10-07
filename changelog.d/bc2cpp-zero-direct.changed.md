- **bc2cpp** closes the `zero?` helper in a closed world that compiles mruby's own Ruby: every
  Numeric that is not a Float runs the compiled `Numeric#zero?` directly, `File.zero?` and
  `FileTest.zero?` receivers raise the argument error their natives raise, and the rest are a
  proven NoMethodError, with no by-name call left in the helper
  (`BC2CPP_CORE_COMPILED_ZERO=0` restores it). The call-facts scan now attributes a name that
  native sources spell only as class-level registrations (ADR 0374).
