- **PSP: the bring-up heartbeat now attributes memory to a scene, and two new
  markers isolate `mrb_open()`'s own cost.** `app/psp/main.cxx`'s
  `RPG2K_PSP_BRINGUP` heartbeat carries a `scene=` field (e.g.
  `RPG2k::Scene::Title`) via a new `#current_scene_name` on `RPG2k`, `RPGXP`
  and `RPGVX` (mruby-rpg2k, mruby-rpgxp, mruby-rpgvx mrblib), so a memory
  snapshot can be attributed to what the player was looking at instead of
  just a frame count. Two new one-shot markers bracket interpreter startup:
  `RPG2K_PSP_PRE_MRUBY_OPEN` (right before `mrb_open()`, LVGL/display already
  live) and the existing `RPG2K_PSP_MRUBY_OPEN` now also carries the same
  memory figures, isolating what opening the interpreter (and defining every
  gem's classes) costs on its own. A third, `RPG2K_PSP_GAME_READY`, fires
  once a game's database/map-tree load and (for RPG2k) `Scene::Title`
  construction finish, before the frame loop has run even once -- "memory
  right before the title screen." Every marker with these figures now also
  carries `t_us=` (`sceKernelGetSystemTimeLow()`), so any two markers'
  timestamps subtract into an elapsed duration (`mrb_open()` cost,
  load-to-title-screen cost, ...) without new profiling code. See
  `docs/adr/0047-psp-memory-budget.md`.
