- **Maix, PSP**: the game boots again. These builds run the engine's Ruby in the interpreter, which looks up
  `attr_writer`, `public` and other core methods by name, so they now keep every core method that Ruby names. The
  PSP build no longer fails on a Wio-only LTO setting, and both firmwares print the exception when a gem fails to
  load at start-up.
