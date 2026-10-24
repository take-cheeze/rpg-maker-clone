- **bc2cpp**: the closed build now leaves 73 more compiled RPG2000/2003 methods out of the method tables. Its
  unregistration list grows from 1126 to 1199 names, mostly scene and battle helpers.
  - `static_dispatch_registrations.rb --closed-only` now counts the names already on the closed list as
    unregistered. Before, rerunning it would have shrunk the checked-in list.
  - New verify mode, `BC2CPP_UNREGISTERED_VERIFY=1`: each unregistered entry gets a stub that aborts on a by-name
    lookup (`unregistered method looked up by name: Class#name`), instead of a `NoMethodError` that game code
    might rescue.
  - New check `scripts/bc2cpp/unregistered_verify_check.rb`; see docs/bc2cpp-unregistered-methods.md.
