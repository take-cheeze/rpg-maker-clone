- `$stderr` lines bridged from Ruby into ng-log (`RGSS::ErrorReport`, see
  `include/terminal.hxx`'s "Stderr log bridge" section) are now stamped with
  the *script* location that logged them — e.g. `Scene_Map:120` — instead of
  every bridged line pointing at the same C++ statement in
  `src/log_bridge.cxx`. `RGSS.__log_bridge_write` (`mruby-rgss/src/lib.cxx`)
  walks the interpreter's call stack to find it, skipping the log bridge's own
  plumbing (`RGSS::ErrorReport`'s tee and `RGSS.warn_once`/`.warn_stub`) so the
  reported frame is the real logging site. A native caller with no script
  location (the non-Ruby diagnostics covered by
  `native-stderr-log-bridge.changed.md`, or bytecode built without debug info)
  falls back to the previous behaviour.
