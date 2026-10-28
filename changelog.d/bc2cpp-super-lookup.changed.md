- **bc2cpp compiles `super(args)` into a C method.** A `super` with arguments
  whose target no direct rule calls (a C method such as
  `Exception#initialize` or `IO#initialize`) is looked up from the superclass
  at run time, as `OP_SUPER` does, and called with the arguments. A literal
  block (`super(x) { }`) still keeps the method bytecode.
  `RGSS::Bitmap::LoadError#initialize` and `File#initialize` now compile.
  `RGSS.effect_probe` keeps its transition sample on `RGSS` instead of a
  captured local, so its hook lambda compiles and the probe with it. An
  embedded-ivar layout is no longer chosen for a class that inherits from a
  built-in type (an Exception, Array or Struct instance), whose fields
  `mrb_data_init` would overwrite.
