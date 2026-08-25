- **`#current_scene_name` (`RPG2k`/`RPGXP`/`RPGVX`) always reported `"none"`.**
  It read `.class.name`, but `Class#name`/`Module#name` lives in the
  `mruby-class-ext` gem, which `build_config.rb` never includes -- so the call
  raised `NoMethodError` every time, silently caught by `app/psp/main.cxx`'s
  `append_scene_name` (a diagnostic marker must never crash the frame loop)
  and reported as `"none"`. Confirmed by the first real-game CI run
  (`psp-smoke-game`, Nepheshel): `RPG2K_PSP_BRINGUP`'s `scene=` stayed `none`
  for 600 frames despite the game actually running. Fixed by switching to
  `.class.to_s`, which resolves through the same `mrb_class_path` machinery
  but is core mruby (`Module#to_s` / `mrb_mod_to_s`), needing no extra gem.
  See `docs/adr/0047-psp-memory-budget.md`'s P1b follow-up.
