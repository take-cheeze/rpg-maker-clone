- **bc2cpp (VM-free builds: Wio, closed):** class-body constants holding a
  Fixnum, Symbol, `true`, `false` or `nil` are no longer defined at boot when
  nothing can read them by name (every read is folded, and nothing reflects
  on constants), and the remaining runs of Fixnum constant writes are set
  from one ROM table. `BC2CPP_CONST_DEF_ELIDE=0` / `BC2CPP_CONST_DEF_TABLE=0`
  restore the inline definitions.
