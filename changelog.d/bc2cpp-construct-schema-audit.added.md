- `tools/bc2cpp/bc2cpp.rb` gains a `== native construct schema audit
  ==` diagnostic: for each `NATIVE_CONSTRUCT_TARGETS` row, the
  library writer's own `mrb_get_args` format string (scraped from the
  native `initialize` body via registration + brace-matching, no
  libclang, no new dependency) is derived to an admitted arity range
  and argument type and checked against the hand-maintained row. A row
  wider than reality or a type disagreement prints a loud `MISMATCH`
  line; unscrapable shapes (lambda inits, Ruby-defined inits) are safe
  `UNRESOLVED` misses. Audit-only -- never consulted by codegen, so
  the regenerated `docs/bc2cpp_coverage.txt` is byte-identical.
