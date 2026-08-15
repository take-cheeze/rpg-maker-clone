- **The PSP EBOOT now starts the real `RPG2k` scene tree.** RGSS was already
  registered the moment `mrb_open()` returned (`libmruby.a`'s gem_init runs
  every bundled gem, RPG2k included) — nothing was reading it yet.
  `app/psp/main.cxx` now sets the `GAME_DIR`/`RTP_DIR` mruby constants
  mruby-rpg2k/mruby-rgss read directly, checks for a project at a fixed
  Memory Stick install location (`ms0:/PSP/GAME/rpg2k`, matching the EBOOT's
  own documented install path), and — if `RPG_RT.ldb` is present — constructs
  `RPG2k` and drives its per-frame `#main_loop` once per C++ loop iteration,
  the same non-blocking shape the Emscripten build's `rpg_start_game`
  callback uses (rather than the desktop build's blocking `#start`, since the
  PSP's own loop has to stay in charge of the process). Construction and a
  clean-exit-vs-crash exit are reported via new `RPG2K_PSP_GAME_START`
  (`ok`/`not_found`/`FAILED`) and `RPG2K_PSP_GAME_STOP` (`exit`/`error`)
  markers, alongside the existing boot/heartbeat ones. RPG Maker XP/VX/VX Ace
  detection, a configurable `GAME_DIR`, and ADR 0047's P2 (the mruby/LVGL
  allocator split) remain open — see `app/psp/README.md`.
