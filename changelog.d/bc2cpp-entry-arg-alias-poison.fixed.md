- bc2cpp: `alias new old` now poisons `old` as well as `new` in the
  ENTRY_ARG_CALLSITE_PROOF call index (shared with the numeric argument
  pooling of ADR 0276), so a parameter is no longer proven Integer from the
  visible calls to `old` while a call through `new` passes another class.
