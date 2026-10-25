- **bc2cpp**: owner calls of `nil?` and `respond_to?` whose every owner is mruby's own C method are now computed in
  place, with no method lookup (OWNER_SET_DIRECT, `tools/bc2cpp/codegen_owner_set_direct.rb`). `nil?` over
  Kernel/NilClass becomes `mrb_nil_p`; `respond_to?(sym)` over Kernel becomes `mrb_respond_to`, with the owner
  call kept for a non-Symbol argument. Each registration is checked against the mruby source
  (`NativeCoreDirect::OWNER_SET_ENTRIES`). `BC2CPP_OWNER_SET_DIRECT=0` turns it off. New check
  `scripts/bc2cpp/owner_set_direct_check.rb`.
