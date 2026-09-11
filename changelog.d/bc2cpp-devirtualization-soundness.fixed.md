- `tools/bc2cpp/bc2cpp.rb`'s devirtualization never checked whether the
  target it was about to call directly would actually compile (only its
  arity), or whether the call site's own argument count matched that
  target's real arity. Both were real, previously-flagged, unfixed gaps: a
  same-owner call into a sibling method dropped by `SKIP_UNSUPPORTED` for
  an unrelated opcode gap could emit a direct call to a `_impl` that's
  never defined (an undefined-reference link failure), and a same-name
  collision between a bytecode method and a differently-arity native one
  (e.g. `Input.repeat?(key)` vs. `Game::MoveRoute#repeat?`) could
  devirtualize straight into a function with the wrong number of
  parameters (a real g++ compile error, 120 occurrences in the closed
  world). Fixed with `compiles_clean?` (memoizes a real `compile_method`
  call rather than re-deriving the opcode-support list by hand a second
  time) and a `mandatory_arity` arg-count check, on both the MONO and the
  class-exact TYPED devirtualization paths. Closes the pre-existing
  434→421-error gap on the full unrestricted closed-world output entirely
  -- it now compiles with 0 errors. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
