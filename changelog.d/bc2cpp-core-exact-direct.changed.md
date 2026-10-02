- **bc2cpp** calls the compiled mruby core body directly when a send has no block and its receiver is
  proven an exact `Array` or `Hash`: the by-name else of the inline `[a, b].min` / `.max`, `uniq`, `fetch`,
  `count`, `sum` and `to_a` become direct calls (81 fewer by-name sends in the wio closed world), only in a
  world where the body provably cannot suspend a Fiber. `BC2CPP_CORE_EXTEND=0` returns the earlier output.
  Covered by `scripts/bc2cpp_core_exact_direct_check.rb` (new `core-exact-direct` CI shard); see
  `docs/adr/0313-bc2cpp-core-exact-direct.md`.
