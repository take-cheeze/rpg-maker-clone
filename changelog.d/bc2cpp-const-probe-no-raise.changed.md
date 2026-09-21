- Compiled code's per-scope constant probe (`bc2cpp_const_try`, used by every
  GETCONST inside a namespaced owner) no longer raises and rescues a NameError
  on each miss. It walks the same ancestor chain `const_get_nohook` does with
  the public `mrb_const_defined_at`, so a miss allocates nothing (the old probe
  allocated an exception, message and backtrace per miss -- ~70k allocations/s
  in the RPG2k map scene, making the desktop bc2cpp build slower than the
  interpreter). It also no longer runs a user `const_missing` on intermediate
  scopes. New `scripts/bc2cpp_const_lookup_check.rb` compares it with the old
  probe against a real mruby core library.
