- **bc2cpp**: hosts can now construct the game through an entry too. `bc2cpp_entry_RPG2k_new(M, argc, argv)` has
  `mrb_obj_new`'s contract. In a closed-world build it allocates the instance and calls the compiled
  `RPG2k#initialize` directly when that is proved to be what `mrb_obj_new` would run; otherwise it calls
  `mrb_obj_new`. The trace, PSP and Maix hosts use it.
  - The PSP host's RPG Maker XP and VX branches use new `bc2cpp_entry_RPGXP_*` / `bc2cpp_entry_RPGVX_*` entries
    (`new`, `main_loop`, `current_scene_name`). No build compiles those gems, so they stay by name.
  - See docs/bc2cpp-entry-points.md.
