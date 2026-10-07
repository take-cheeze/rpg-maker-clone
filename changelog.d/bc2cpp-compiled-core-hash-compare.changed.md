- **bc2cpp** closes the Hash arm of the `< <= > >=` helpers in a closed world that compiles
  mruby's own Ruby: the helper calls the compiled `Hash#<` family behind an exact-Hash test
  instead of dispatching by name (`BC2CPP_CORE_COMPILED_CMP=0` restores the by-name call). A new
  `CORE_COMPILED_DEFINERS` view makes the run's compiled core definitions visible to the
  closed-world answers without touching the registry, and the build now lists every core-source
  method it leaves interpreted with the reason (ADR 0371).
