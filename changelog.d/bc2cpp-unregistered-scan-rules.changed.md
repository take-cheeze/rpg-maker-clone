- **bc2cpp**: the closed build now leaves 288 more compiled RPG2000/2003 methods out of the method tables. Its
  unregistration list grows from 1199 to 1487 names.
  - Generated-C uses that look nothing up no longer keep a name registered: `bc2cpp_nomethod(_raise)`,
    `bc2cpp_guard_violation`, `bc2cpp_hint_violation` and `bc2cpp_nil_receiver`.
  - The closed scan of outside sources skips the other makers' gems, which the single-format closed build
    doesn't load. In native files it counts only string literals, presym operands and the arguments of
    macros that turn an argument into a name, not every C identifier.
  - `scripts/bc2cpp/trace_host.cxx` takes `BC2CPP_HOST_BATTLE_TROOP` / `BC2CPP_HOST_BATTLE_PLAY`, so a
    verify-mode trace can open and drive a battle.
  - New check `scripts/bc2cpp/static_dispatch_scan_check.rb`.
