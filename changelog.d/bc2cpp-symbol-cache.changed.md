- Generated compiled code no longer interns names on every execution. Each
  distinct ivar/constant/method name and symbol literal is interned once per VM
  and read from a file-scope table (`bc2cpp_sym`), and `mrb_funcall(M, r,
  "name", ...)` becomes `mrb_funcall_id` on the cached id. A stack sample of the
  desktop `RPGMAKER_BC2CPP` build on the RPG2k map scene had ~33% of busy time
  in `sym_intern`/`find_symbol`/`presym_find`, mostly inside
  `Game::Interpreter#execute`'s command switch. The cache is keyed on the
  `mrb_state` and reset from each compiled gem's `gem_final`. New
  `scripts/bc2cpp_symbol_cache_check.rb` covers the rewrite and the cache's
  per-VM behaviour.
