- **Wio: the firmware's own code reads `mrb_state` as libmruby lays it out.**
  `build_config.rb` shrinks the GC gray stack and the method caches for the
  Wio libmruby, but the PlatformIO build of `app/wio` used mruby's default
  sizes, so its inline GC arena save/restore (`bc2cpp_entry.hxx`) read and
  wrote the wrong words. `platformio.ini` now passes the same three defines,
  and the firmware refuses to boot if the two sizes of `mrb_state` differ.
