- Every `$stderr` line the runtime logs (the `[RGSS]`/`[RPG2k]`/`[RPGXP]`/
  `[MV]`/`[MZ]`-tagged diagnostics `RGSS::ErrorReport` already tees into a
  crash report's log tail) now also reaches ng-log via `LOG(WARNING)`, so it
  respects ng-log's severity filtering and shows up in the on-screen terminal
  log console alongside the engine's other logging. The bridge is a runtime
  hook the executable installs at start-up (`src/log_bridge.cxx`); the
  `mruby-rgss` gem's half is a bare function pointer with no ng-log type in
  it, so `mrbtest`, the PSP build and the Wio Terminal firmware — which never
  install the hook and stay free of a compile-time ng-log dependency per ADR
  0005 — see `$stderr` behave exactly as before.
