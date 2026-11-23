- **bc2cpp**: a declaration-check or guard-violation site names its method
  through a per-gem ROM table row (owner, presym name, tail) instead of an
  `"Owner#name"` string, and the symbol table and frame-free rows keep no string
  for a name presym spells (`COMPACT_LABELS`, `BC2CPP_COMPACT_LABELS=0`,
  `BC2CPP_SYM_DYN_NAMES=0`, `BC2CPP_FRAME_FREE_PRESYM=0` turn them off). The
  violation messages are unchanged; the Wio Terminal image shrinks by 33 KB.
