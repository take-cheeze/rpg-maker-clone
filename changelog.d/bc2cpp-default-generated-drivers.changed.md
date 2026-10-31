- The bc2cpp enum step (`tools/bc2cpp/codegen_enum_step.rb`) now covers every
  guarded core method that has a Ruby body, not only the hand-written forms.
  Each such method's driver is generated from its own `def`
  (`tools/bc2cpp/enum_driver_gen.rb`), so a `Fiber.yield` in the block suspends
  through VM frames only. Methods the generator refuses (no `&block`,
  `block_given?`, `super`, a reassigned block) keep their saved bytecode.
  `BC2CPP_ENUM_STEP=0` turns this off, as before.
