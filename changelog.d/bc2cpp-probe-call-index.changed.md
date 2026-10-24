- **bc2cpp**: a Symbol literal that only reaches `respond_to?`'s name argument
  no longer counts as a call of that name in the entry-argument call-site index
  (ENTRY_ARG_CALLSITE_PROOF), and a self send reusing the probe register as its
  result slot no longer counts as a use of the name (PROBE_ONLY), so setter
  pools probed with `respond_to?(:name=)` stop being poisoned (10 on the closed
  world). `BC2CPP_PROBE_CALL_INDEX=0` keeps every literal a poison; checked by
  `scripts/bc2cpp/dynamic_names_probe_check.rb`.
