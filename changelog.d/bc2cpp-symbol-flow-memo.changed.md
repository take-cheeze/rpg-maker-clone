- **bc2cpp** memoizes `IrSymbolFlow`'s per-irep queries: `captured_regs`
  (the whole-tree GETUPVAR walk ran on every `value_reads` call) is
  computed once per irep object, and `value_reads` walks are memoized
  per `[index, register]` with a 1024-entry cap. `BC2CPP_SYMBOL_FLOW_MEMO=0`
  restores recomputation. Engine `type_check` output is byte-identical.
