- **bc2cpp** compiles faster: strict-superclass sets, per-subtree ivar name
  sets and each irep's ENTER lookup are computed once instead of per query
  (`CodeGen#strict_subclass?`, `#irep_subtree_touches_ivar?`, `Irep#enter`).
  Generated output is byte-identical.
