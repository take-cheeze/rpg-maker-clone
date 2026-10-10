- **bc2cpp** (ADR 0397): a by-name send on a receiver the flow does not prove exact gets, ahead of its by-name else, one
  exact-class arm per Ruby definition of the name when a new owner map (`native_owner_map.rb`) proves that no native
  registration lands on that class. The arm calls the class's compiled body; the else is unchanged. Core forwarders
  (`define_method`, `alias`, `prepend`, `attr_*` in `3rd/mruby`) are trusted by default; `BC2CPP_NATIVE_OWNER_MAP=strict`
  refuses them and `BC2CPP_NATIVE_OWNER_MAP=0` restores the previous output byte for byte. On the shipped wio build 241
  sites get an arm and no by-name send is removed. Check `scripts/bc2cpp_native_owner_map_check.rb`.
