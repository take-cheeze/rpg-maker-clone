- **bc2cpp**: compile keyword-argument call sites (docs/adr/0151) --
  `SEND`/`SSEND` with `nk>0` now devirtualizes into the compiled
  callee's `_impl` (MONO-only, literal-symbol keys), unblocking 10
  methods (`RPG2k#fire_preview_animation`, 3 `Scene::Battle`,
  `DebugMenu#play_animation`, 5 `Scene::Map`). All 10 registered;
  zero regressions (1651 -> 1661 clean).
