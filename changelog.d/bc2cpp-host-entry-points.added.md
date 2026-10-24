- **Closed-world hosts call compiled entry points directly.** The PSP, Maix
  and trace hosts now call `RPG2k#main_loop` and `#current_scene_name` through
  `include/bc2cpp_entry.hxx`. In a bc2cpp build these calls run the compiled
  method bodies directly, with `mrb_funcall`'s error behaviour. Other builds
  call by name, as before (docs/bc2cpp-entry-points.md).
